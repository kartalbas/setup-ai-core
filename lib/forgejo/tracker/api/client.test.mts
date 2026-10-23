import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { after, before, describe, it } from 'node:test';
import { createTokenSource } from './credentials.mts';
import {
  AuthenticationError,
  CONNECT_TIMEOUT_MS,
  ContractError,
  ForgejoClient,
  NotFoundError,
  PAGE_LIMIT,
  PermissionError,
  TOTAL_TIMEOUT_MS,
  TransportError,
  segment,
} from './client.mts';
import type { Operation } from './client.mts';
import { issueShape } from './shapes.mts';
import type { Issue } from './shapes.mts';
import { FAKE_TOKEN, clientFor, startFakeForgejo } from '../testing/fake-forgejo.mts';
import type { FakeForgejo } from '../testing/fake-forgejo.mts';

function readIssue(number: number): Operation<Issue> {
  return { name: `read issue o/r#${number}`, method: 'GET', path: `/repos/o/r/issues/${segment(number)}`, success: 200, read: issueShape.type.read };
}
function editIssue(number: number, title: string): Operation<Issue> {
  return { name: `edit issue o/r#${number}`, method: 'PATCH', path: `/repos/o/r/issues/${number}`, body: { title }, success: 201, read: issueShape.type.read };
}

describe('the request timeouts', () => {
  it('are the values of lib/common.sh', () => {
    const common = readFileSync(new URL('../../../common.sh', import.meta.url), 'utf8');
    assert.match(common, /--connect-timeout 15 --max-time 120/);
    assert.equal(CONNECT_TIMEOUT_MS, 15_000);
    assert.equal(TOTAL_TIMEOUT_MS, 120_000);
  });
});

describe('the HTTP contract', () => {
  let fake: FakeForgejo;
  before(async () => {
    fake = await startFakeForgejo();
    fake.addRepository('o/r');
    fake.addIssue('o/r', { title: 'First, so that there is one' });
  });
  after(async () => {
    await fake.close();
  });

  it('reads a swagger-conforming answer (innocent case)', async () => {
    const issue = await clientFor(fake).call(readIssue(1));
    assert.equal(issue.title, 'First, so that there is one');
    assert.equal(issue.number, 1);
  });

  it('accepts the documented 201 of a PATCH (innocent case)', async () => {
    const issue = await clientFor(fake).call(editIssue(1, 'Edited, so that it is proven'));
    assert.equal(issue.title, 'Edited, so that it is proven');
  });

  it('refuses a PATCH that answers 200 where 201 is documented, and names the operation', async () => {
    fake.fail({ method: 'PATCH', path: '/repos/o/r/issues/1', mode: { kind: 'success-status', status: 200 } });
    await assert.rejects(clientFor(fake).call(editIssue(1, 'Third')), (error: unknown) => {
      assert.ok(error instanceof ContractError);
      assert.match(error.message, /^edit issue o\/r#1: .*documented success status is 201 and Forgejo answered 200/);
      return true;
    });
  });

  it('refuses an answer that is not JSON', async () => {
    fake.fail({ path: '/repos/o/r/issues/1', mode: { kind: 'malformed' } });
    await assert.rejects(clientFor(fake).call(readIssue(1)), (error: unknown) => error instanceof ContractError && /is not JSON/.test(error.message));
  });

  it('refuses an answer that lacks a field the client needs', async () => {
    fake.fail({ path: '/repos/o/r/issues/1', mode: { kind: 'omit-field', field: 'title' } });
    await assert.rejects(clientFor(fake).call(readIssue(1)), (error: unknown) => error instanceof ContractError && /lacks the required field title/.test(error.message));
  });

  it('tells 401, 403 and 404 apart, each with its operation', async () => {
    const wrong = new ForgejoClient({ baseUrl: fake.url, token: createTokenSource("printf '%s' not-the-token") });
    await assert.rejects(wrong.call(readIssue(1)), (error: unknown) => error instanceof AuthenticationError && /^read issue o\/r#1: /.test(error.message));
    fake.fail({ path: '/repos/o/r/issues/1', mode: { kind: 'status', status: 403, message: 'no scope' } });
    await assert.rejects(clientFor(fake).call(readIssue(1)), (error: unknown) => error instanceof PermissionError && /no scope/.test(error.message));
    await assert.rejects(clientFor(fake).call(readIssue(99)), (error: unknown) => error instanceof NotFoundError && /^read issue o\/r#99: /.test(error.message));
  });

  it('refuses any other status as a contract failure', async () => {
    fake.fail({ path: '/repos/o/r/issues/1', mode: { kind: 'status', status: 500, message: 'boom' } });
    await assert.rejects(clientFor(fake).call(readIssue(1)), (error: unknown) => error instanceof ContractError && /answered 500/.test(error.message));
  });

  it('keeps the token out of a server error (planted: the server repeats it)', async () => {
    fake.fail({ path: '/repos/o/r/issues/1', mode: { kind: 'status', status: 422, message: `the token ${FAKE_TOKEN} is bad` } });
    await assert.rejects(clientFor(fake).call(readIssue(1)), (error: unknown) => {
      assert.ok(error instanceof ContractError);
      assert.ok(!error.message.includes(FAKE_TOKEN));
      assert.match(error.message, /\[token\]/);
      return true;
    });
  });

  it('keeps the token out of the message when the server says nothing of it (innocent case)', async () => {
    fake.fail({ path: '/repos/o/r/issues/1', mode: { kind: 'status', status: 422, message: 'title is required' } });
    await assert.rejects(clientFor(fake).call(readIssue(1)), (error: unknown) => error instanceof ContractError && /title is required/.test(error.message));
  });
});

describe('transport failures', () => {
  let fake: FakeForgejo;
  before(async () => {
    fake = await startFakeForgejo();
    fake.addRepository('o/r');
    fake.addIssue('o/r', { title: 'Only, so that there is one' });
  });
  after(async () => {
    await fake.close();
  });

  it('reports a read without an answer as certain: nothing was written', async () => {
    fake.fail({ path: '/repos/o/r/issues/1', mode: { kind: 'drop-before' } });
    await assert.rejects(clientFor(fake).call(readIssue(1)), (error: unknown) => error instanceof TransportError && !error.uncertain);
  });

  it('reports a write whose answer was lost as uncertain, and sends it once', async () => {
    fake.fail({ method: 'PATCH', path: '/repos/o/r/issues/1', mode: { kind: 'drop-after' } });
    const before = fake.writes().length;
    await assert.rejects(clientFor(fake).call(editIssue(1, 'Lost, so that it is proven')), (error: unknown) => {
      assert.ok(error instanceof TransportError);
      assert.equal(error.uncertain, true);
      assert.match(error.message, /may have happened/);
      return true;
    });
    assert.equal(fake.writes().length - before, 1);
    assert.equal(fake.readIssue('o/r', 1).title, 'Lost, so that it is proven');
  });

  it('ends a request that never gets an answer at the total timeout', async () => {
    fake.fail({ path: '/repos/o/r/issues/1', mode: { kind: 'stall' } });
    await assert.rejects(clientFor(fake, { totalTimeoutMs: 150 }).call(readIssue(1)), (error: unknown) => error instanceof TransportError && /no answer within 0.15 seconds/.test(error.message));
  });

  it('reports a server that is not there', async () => {
    const lonely = new ForgejoClient({ baseUrl: 'http://127.0.0.1:1', token: createTokenSource("printf '%s' t"), connectTimeoutMs: 500 });
    await assert.rejects(lonely.call(readIssue(1)), (error: unknown) => error instanceof TransportError && /^read issue o\/r#1: /.test(error.message));
  });
});

describe('paging', () => {
  let fake: FakeForgejo;
  before(async () => {
    fake = await startFakeForgejo({ pageMaximum: 30 });
    fake.addRepository('o/r');
    for (let n = 1; n <= 75; n++) fake.addIssue('o/r', { title: `Issue ${n}, so that there are many` });
  });
  after(async () => {
    await fake.close();
  });

  it('reads every page, also when the server caps a page below the limit asked for', async () => {
    const issues = await clientFor(fake).callAll({ name: 'search issues', path: '/repos/issues/search', query: { type: 'issues', owner: 'o', state: 'all' }, readItem: issueShape.type.read });
    assert.equal(issues.length, 75);
    assert.equal(new Set(issues.map((issue) => issue.number)).size, 75);
    assert.ok(PAGE_LIMIT > 30);
  });

  it('refuses a list that ends before the total the server announced (planted: it stops early)', async () => {
    const server = createServer((request, response) => {
      const page = new URL(request.url ?? '/', 'http://localhost').searchParams.get('page');
      response.writeHead(200, { 'Content-Type': 'application/json', 'X-Total-Count': '5' });
      response.end(page === '1' ? JSON.stringify([stubIssue(1), stubIssue(2)]) : '[]');
    });
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    const { port } = server.address() as AddressInfo;
    try {
      const client = new ForgejoClient({ baseUrl: `http://127.0.0.1:${port}`, token: createTokenSource("printf '%s' t") });
      await assert.rejects(client.callAll({ name: 'search issues', path: '/repos/issues/search', readItem: issueShape.type.read }), (error: unknown) => error instanceof ContractError && /announced 5 items and stopped after 2/.test(error.message));
    } finally {
      server.closeAllConnections();
      server.close();
    }
  });

  async function pagedAnswers(pages: Record<string, string>, run: (client: ForgejoClient) => Promise<unknown>): Promise<unknown> {
    const server = createServer((request, response) => {
      const page = new URL(request.url ?? '/', 'http://localhost').searchParams.get('page') ?? '1';
      response.writeHead(200, { 'Content-Type': 'application/json', 'X-Total-Count': page === '1' ? '2' : '0' });
      response.end(pages[page] ?? 'null');
    });
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    const { port } = server.address() as AddressInfo;
    try {
      return await run(new ForgejoClient({ baseUrl: `http://127.0.0.1:${port}`, token: createTokenSource("printf '%s' t") }));
    } finally {
      server.closeAllConnections();
      server.close();
    }
  }
  const readTwo = (client: ForgejoClient): Promise<Issue[]> =>
    client.callAll({ name: 'read the timeline', path: '/t', readItem: issueShape.type.read, totalCountsPage: true });

  it('ends a list at a page whose body is null, as Forgejo answers a page of the timeline past its end', async () => {
    const issues = (await pagedAnswers({ 1: JSON.stringify([stubIssue(1), stubIssue(2)]), 2: 'null' }, readTwo)) as Issue[];
    assert.deepEqual(issues.map((issue) => issue.number), [1, 2]);
  });

  it('reads a first page whose body is null as an empty list, for an issue with no timeline entries', async () => {
    assert.deepEqual(await pagedAnswers({ 1: 'null' }, readTwo), []);
  });

  it('still refuses a page that is neither a list nor null (planted: an object, a string)', async () => {
    for (const body of ['{}', '"x"', '7']) {
      await assert.rejects(pagedAnswers({ 1: JSON.stringify([stubIssue(1)]), 2: body }, readTwo), (error: unknown) => error instanceof ContractError && /read the timeline \(page 2\).*a list was expected/.test(error.message));
    }
  });
});

function stubIssue(number: number): unknown {
  return { number, title: `Stub ${number}`, body: '', state: 'open', labels: [], assignees: null, comments: 0, created_at: '2026-01-01T00:00:00Z', html_url: 'https://forge.example.test/o/r/issues/1' };
}
