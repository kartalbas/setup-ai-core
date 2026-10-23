import { spawn } from 'node:child_process';
import { CredentialsError } from './client.mts';
import type { TokenSource } from './client.mts';

const COMMAND_TIMEOUT_MS = 30_000;

export interface CommandOutcome {
  readonly exitCode: number | null;
  readonly signal: NodeJS.Signals | null;
  readonly stdout: string;
  readonly timedOut: boolean;
}

export type CommandRunner = (command: string) => Promise<CommandOutcome>;

const runShellCommand: CommandRunner = (command) =>
  new Promise<CommandOutcome>((resolve, reject) => {
    const child = spawn('bash', ['-c', command], { stdio: ['ignore', 'pipe', 'ignore'] });
    const chunks: Buffer[] = [];
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGKILL');
    }, COMMAND_TIMEOUT_MS);
    child.stdout.on('data', (chunk: Buffer) => chunks.push(chunk));
    child.on('error', (error: Error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on('close', (exitCode, signal) => {
      clearTimeout(timer);
      resolve({ exitCode, signal, stdout: Buffer.concat(chunks).toString('utf8'), timedOut });
    });
  });

// The token comes from running FORGEJO_TOKEN_COMMAND. What the command prints or says on stderr
// is never part of a message, because a failing command may print the secret it was to hand over.
export function createTokenSource(command: string, run: CommandRunner = runShellCommand): TokenSource {
  const operation = 'read the Forgejo token';
  let token: string | undefined;
  let pending: Promise<string> | undefined;

  const obtain = async (): Promise<string> => {
    let outcome: CommandOutcome;
    try {
      outcome = await run(command);
    } catch {
      throw new CredentialsError(operation, 'FORGEJO_TOKEN_COMMAND could not be started');
    }
    if (outcome.timedOut) throw new CredentialsError(operation, 'FORGEJO_TOKEN_COMMAND did not finish in time');
    if (outcome.exitCode !== 0) {
      const how = outcome.exitCode === null ? `was stopped by ${outcome.signal ?? 'a signal'}` : `exited with status ${outcome.exitCode}`;
      throw new CredentialsError(operation, `FORGEJO_TOKEN_COMMAND ${how}`);
    }
    const value = outcome.stdout.replace(/\r?\n$/, '');
    if (value === '') throw new CredentialsError(operation, 'FORGEJO_TOKEN_COMMAND printed no token');
    if (/\s/.test(value)) throw new CredentialsError(operation, 'FORGEJO_TOKEN_COMMAND printed more than one token');
    return value;
  };

  return {
    read(): Promise<string> {
      if (token !== undefined) return Promise.resolve(token);
      pending ??= obtain().then(
        (value) => {
          token = value;
          return value;
        },
        (error: unknown) => {
          pending = undefined;
          throw error;
        },
      );
      return pending;
    },
    redact(text: string): string {
      return token === undefined || token === '' ? text : text.split(token).join('[token]');
    },
  };
}
