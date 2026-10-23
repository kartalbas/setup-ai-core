import { request as requestHttp } from 'node:http';
import type { IncomingHttpHeaders } from 'node:http';
import { request as requestHttps } from 'node:https';

// The values of the Bash part: lib/common.sh gives every HTTP call --connect-timeout 15 --max-time 120.
export const CONNECT_TIMEOUT_MS = 15_000;
export const TOTAL_TIMEOUT_MS = 120_000;
export const PAGE_LIMIT = 50;
const MAXIMUM_PAGES = 10_000;
const MAXIMUM_SERVER_MESSAGE_LENGTH = 200;

export type ErrorKind =
  | 'authentication'
  | 'permission'
  | 'not-found'
  | 'transport'
  | 'contract'
  | 'configuration'
  | 'partial';

export class ForgejoError extends Error {
  readonly kind: ErrorKind;
  readonly operation: string;

  constructor(kind: ErrorKind, operation: string, detail: string) {
    super(`${operation}: ${detail}`);
    this.name = new.target.name;
    this.kind = kind;
    this.operation = operation;
  }
}

export class AuthenticationError extends ForgejoError {
  constructor(operation: string, detail: string) {
    super('authentication', operation, detail);
  }
}

export class PermissionError extends ForgejoError {
  constructor(operation: string, detail: string) {
    super('permission', operation, detail);
  }
}

export class NotFoundError extends ForgejoError {
  constructor(operation: string, detail: string) {
    super('not-found', operation, detail);
  }
}

export class TransportError extends ForgejoError {
  // True when a write was sent and no answer came back, so it may have happened.
  readonly uncertain: boolean;

  constructor(operation: string, detail: string, uncertain: boolean) {
    super('transport', operation, detail);
    this.uncertain = uncertain;
  }
}

export class ContractError extends ForgejoError {
  constructor(operation: string, detail: string) {
    super('contract', operation, detail);
  }
}

export class CredentialsError extends ForgejoError {
  constructor(operation: string, detail: string) {
    super('configuration', operation, detail);
  }
}

export class PartialCompletionError extends ForgejoError {
  readonly completed: readonly string[];

  constructor(operation: string, completed: readonly string[], detail: string) {
    super('partial', operation, `${detail}. Done before it failed: ${completed.length > 0 ? completed.join('; ') : 'nothing'}`);
    this.completed = completed;
  }
}

export type Method = 'GET' | 'POST' | 'PATCH' | 'DELETE';
export type Reader<T> = (value: unknown, where: string) => T;

export type QueryValue = string | number | undefined;

export interface Operation<T> {
  readonly name: string;
  readonly method: Method;
  readonly path: string;
  readonly query?: Readonly<Record<string, QueryValue>>;
  readonly body?: unknown;
  readonly success: number;
  readonly read: Reader<T>;
}

export interface PagedOperation<T> {
  readonly name: string;
  readonly path: string;
  readonly query?: Readonly<Record<string, QueryValue>>;
  readonly readItem: Reader<T>;
}

export interface TokenSource {
  read(): Promise<string>;
  redact(text: string): string;
}

export interface ClientOptions {
  readonly baseUrl: string;
  readonly token: TokenSource;
  readonly connectTimeoutMs?: number;
  readonly totalTimeoutMs?: number;
}

interface RawResponse {
  readonly status: number;
  readonly headers: IncomingHttpHeaders;
  readonly text: string;
}

export function expectNoBody(value: unknown, where: string): undefined {
  if (value !== undefined) throw new ContractError(where, 'an answer without a body was expected');
  return undefined;
}

export function segment(value: string | number): string {
  return encodeURIComponent(String(value));
}

export class ForgejoClient {
  private readonly baseUrl: URL;
  private readonly token: TokenSource;
  private readonly connectTimeoutMs: number;
  private readonly totalTimeoutMs: number;

  constructor(options: ClientOptions) {
    this.baseUrl = new URL(options.baseUrl);
    this.token = options.token;
    this.connectTimeoutMs = options.connectTimeoutMs ?? CONNECT_TIMEOUT_MS;
    this.totalTimeoutMs = options.totalTimeoutMs ?? TOTAL_TIMEOUT_MS;
  }

  async call<T>(operation: Operation<T>): Promise<T> {
    const raw = await this.exchange(operation.name, operation.method, operation.path, operation.query, operation.body);
    return this.interpret(operation, raw);
  }

  // Every page, until the server's total is reached. A list shorter than the total, or a page that
  // ends the list early, is a contract failure and never a shorter result.
  async callAll<T>(operation: PagedOperation<T>): Promise<T[]> {
    const items: T[] = [];
    for (let page = 1; page <= MAXIMUM_PAGES; page++) {
      const query = { ...operation.query, page, limit: PAGE_LIMIT };
      const raw = await this.exchange(operation.name, 'GET', operation.path, query, undefined);
      const pageItems = this.interpret(
        {
          name: `${operation.name} (page ${page})`,
          success: 200,
          read: (value: unknown, where: string): T[] => {
            if (!Array.isArray(value)) throw new ContractError(where, 'a list was expected');
            return value.map((item: unknown, index: number) => operation.readItem(item, `${where}[${index}]`));
          },
        },
        raw,
      );
      items.push(...pageItems);
      const total = parseTotal(raw.headers['x-total-count']);
      if (total !== undefined) {
        if (items.length >= total) return items;
        if (pageItems.length === 0) {
          throw new ContractError(operation.name, `the server announced ${total} items and stopped after ${items.length}`);
        }
      } else if (pageItems.length === 0) {
        return items;
      }
    }
    throw new ContractError(operation.name, `more than ${MAXIMUM_PAGES} pages`);
  }

  private interpret<T>(operation: Pick<Operation<T>, 'name' | 'success' | 'read'>, raw: RawResponse): T {
    const { name } = operation;
    if (raw.status === operation.success) {
      if (raw.text.length === 0) return operation.read(undefined, name);
      let value: unknown;
      try {
        value = JSON.parse(raw.text);
      } catch {
        throw new ContractError(name, `the answer (status ${raw.status}) is not JSON`);
      }
      return operation.read(value, name);
    }
    const said = this.serverMessage(raw.text);
    const suffix = said === '' ? '' : `: ${said}`;
    if (raw.status === 401) throw new AuthenticationError(name, `Forgejo does not accept the token (401)${suffix}`);
    if (raw.status === 403) throw new PermissionError(name, `the token may not do this (403)${suffix}`);
    if (raw.status === 404) throw new NotFoundError(name, `Forgejo has no such thing (404)${suffix}`);
    throw new ContractError(name, `the documented success status is ${operation.success} and Forgejo answered ${raw.status}${suffix}`);
  }

  private serverMessage(text: string): string {
    let said = '';
    try {
      const value: unknown = JSON.parse(text);
      if (typeof value === 'object' && value !== null && 'message' in value && typeof value.message === 'string') said = value.message;
    } catch {
      said = '';
    }
    said = this.token.redact(said).replace(/\s+/g, ' ').trim();
    return said.length > MAXIMUM_SERVER_MESSAGE_LENGTH ? `${said.slice(0, MAXIMUM_SERVER_MESSAGE_LENGTH)}...` : said;
  }

  private async exchange(name: string, method: Method, path: string, query: Readonly<Record<string, QueryValue>> | undefined, body: unknown): Promise<RawResponse> {
    const token = await this.token.read();
    const url = new URL(`${this.baseUrl.origin}/api/v1${path}`);
    for (const [key, value] of Object.entries(query ?? {})) {
      if (value !== undefined) url.searchParams.set(key, String(value));
    }
    const payload = body === undefined ? undefined : JSON.stringify(body);
    const headers: Record<string, string> = { Authorization: `token ${token}`, Accept: 'application/json', 'User-Agent': 'ai-core-forgejo-tracker' };
    if (payload !== undefined) {
      headers['Content-Type'] = 'application/json';
      headers['Content-Length'] = String(Buffer.byteLength(payload));
    }
    return this.send(name, method, url, headers, payload);
  }

  private send(name: string, method: Method, url: URL, headers: Record<string, string>, payload: string | undefined): Promise<RawResponse> {
    const connectTimeoutMs = this.connectTimeoutMs;
    const totalTimeoutMs = this.totalTimeoutMs;
    const redact = (text: string): string => this.token.redact(text);
    return new Promise<RawResponse>((resolve, reject) => {
      let sent = false;
      let settled = false;
      const timers: NodeJS.Timeout[] = [];
      const finish = (action: () => void): void => {
        if (settled) return;
        settled = true;
        for (const timer of timers) clearTimeout(timer);
        action();
      };
      const fail = (detail: string): void => {
        finish(() => {
          const uncertain = method !== 'GET' && sent;
          const tail = uncertain ? '. The request was sent, so the write may have happened; read the issue before repeating it' : '';
          reject(new TransportError(name, `${redact(detail)}${tail}`, uncertain));
        });
      };
      const open = url.protocol === 'https:' ? requestHttps : requestHttp;
      const request = open(url, { method, headers, agent: false }, (response) => {
        const chunks: Buffer[] = [];
        response.on('data', (chunk: Buffer) => chunks.push(chunk));
        response.on('error', (error: Error) => {
          fail(`the answer broke off (${error.message})`);
        });
        response.on('aborted', () => {
          fail('the answer broke off');
        });
        response.on('end', () => {
          finish(() => resolve({ status: response.statusCode ?? 0, headers: response.headers, text: Buffer.concat(chunks).toString('utf8') }));
        });
      });
      timers.push(
        setTimeout(() => {
          request.destroy();
          fail(`no connection within ${connectTimeoutMs / 1000} seconds`);
        }, connectTimeoutMs),
      );
      timers.push(
        setTimeout(() => {
          request.destroy();
          fail(`no answer within ${totalTimeoutMs / 1000} seconds`);
        }, totalTimeoutMs),
      );
      request.on('finish', () => {
        sent = true;
        clearTimeout(timers[0]);
      });
      request.on('error', (error: Error) => {
        fail(`${method} ${url.pathname} failed (${error.message})`);
      });
      request.end(payload);
    });
  }
}

function parseTotal(header: string | string[] | undefined): number | undefined {
  if (typeof header !== 'string') return undefined;
  const total = Number(header);
  return Number.isInteger(total) && total >= 0 ? total : undefined;
}
