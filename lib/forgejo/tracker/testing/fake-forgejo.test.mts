import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import { FAKE_TOKEN, startFakeForgejo } from './fake-forgejo.mts';
import type { FakeForgejo } from './fake-forgejo.mts';

async function call(fake: FakeForgejo, method: string, path: string, body?: unknown, token: string | null = FAKE_TOKEN): Promise<{ status: number; json: unknown; headers: Headers }> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (token !== null) headers.Authorization = `token ${token}`;
  const response = await fetch(`${fake.url}/api/v1${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await response.text();
  return { status: response.status, json: text === '' ? undefined : (JSON.parse(text) as unknown), headers: response.headers };
}

describe('the fake Forgejo refuses what the contract refuses', () => {
  let fake: FakeForgejo;
  before(async () => {
    fake = await startFakeForgejo();
    fake.addRepository('o/r');
    fake.addLabel('o', { name: 'status/ready', exclusive: true });
    fake.addLabel('o', { name: 'status/testing', exclusive: true });
    fake.addLabel('o', { name: 'area/gate' });
    fake.addIssue('o/r', { title: 'First, so that there is one', labels: ['status/ready', 'area/gate'] });
  });
  after(async () => {
    await fake.close();
  });

  it('answers a conforming request with the documented status (innocent case)', async () => {
    const created = await call(fake, 'POST', '/repos/o/r/issues', { title: 'A new issue, so that it is made' });
    assert.equal(created.status, 201);
    const edited = await call(fake, 'PATCH', '/repos/o/r/issues/2', { title: 'Renamed, so that it is edited' });
    assert.equal(edited.status, 201);
    assert.equal((await call(fake, 'GET', '/repos/o/r/issues/2')).status, 200);
  });

  it('numbers the issues of a repository one after the other', async () => {
    const first = (await call(fake, 'POST', '/repos/o/r/issues', { title: 'Third' })).json as { number: number };
    const second = (await call(fake, 'POST', '/repos/o/r/issues', { title: 'Fourth' })).json as { number: number };
    assert.equal(second.number, first.number + 1);
  });

  it('refuses a request without the token', async () => {
    assert.equal((await call(fake, 'GET', '/repos/o/r/issues/1', undefined, null)).status, 401);
    assert.equal((await call(fake, 'GET', '/repos/o/r/issues/1', undefined, 'another')).status, 401);
  });

  it('refuses a path or a method that api/schema.json does not hold', async () => {
    assert.equal((await call(fake, 'GET', '/repos/o/r/pulls')).status, 404);
    assert.equal((await call(fake, 'PUT', '/repos/o/r/issues/1/labels', { labels: [1] })).status, 405);
    assert.equal((await call(fake, 'DELETE', '/repos/o/r/issues/1')).status, 405);
  });

  it('refuses a body field the definition does not name, a missing required field and a wrong type', async () => {
    assert.equal((await call(fake, 'POST', '/repos/o/r/issues', { title: 'x', unknown: 1 })).status, 422);
    assert.equal((await call(fake, 'POST', '/repos/o/r/issues', { body: 'no title' })).status, 422);
    assert.equal((await call(fake, 'POST', '/repos/o/r/issues', { title: 5 })).status, 422);
    assert.equal((await call(fake, 'POST', '/repos/o/r/issues/1/dependencies', { owner: 'o', repo: 'r' })).status, 422);
  });

  it('refuses an index that is no integer and a query parameter the operation does not have', async () => {
    assert.equal((await call(fake, 'GET', '/repos/o/r/issues/one')).status, 422);
    assert.equal((await call(fake, 'GET', '/repos/issues/search?nonsense=1')).status, 422);
  });

  it('keeps one label of an exclusive scope when another is added, as Forgejo does', async () => {
    const before = fake.readIssue('o/r', 1).labels.sort();
    assert.deepEqual(before, ['area/gate', 'status/ready']);
    const added = await call(fake, 'POST', '/repos/o/r/issues/1/labels', { labels: ['status/testing'] });
    assert.equal(added.status, 200);
    assert.deepEqual(fake.readIssue('o/r', 1).labels.sort(), ['area/gate', 'status/testing']);
  });

  it('pages a list and announces its total', async () => {
    for (let n = 0; n < 60; n++) fake.addIssue('o/r', { title: `Many ${n}, so that there are pages` });
    const page = await call(fake, 'GET', '/repos/issues/search?type=issues&owner=o&state=all&limit=50&page=2');
    assert.equal(page.status, 200);
    assert.equal(Number(page.headers.get('x-total-count')) > 60, true);
    assert.equal((page.json as unknown[]).length, Number(page.headers.get('x-total-count')) - 50);
  });

  it('lets a rule injected for a test fire the number of times it says (planted failure and the next call)', async () => {
    fake.fail({ path: '/repos/o/r/issues/1', mode: { kind: 'status', status: 500, message: 'planted' } });
    assert.equal((await call(fake, 'GET', '/repos/o/r/issues/1')).status, 500);
    assert.equal((await call(fake, 'GET', '/repos/o/r/issues/1')).status, 200);
  });
});

describe('the fake Forgejo answers the lifecycle paths as the swagger documents them', () => {
  let fake: FakeForgejo;
  before(async () => {
    fake = await startFakeForgejo();
    fake.addRepository('o/r');
    fake.addTag('o/r', 'v1');
    fake.addIssue('o/r', { title: 'First, so that there is one' });
    fake.setPermission('o/r', 'writer', 'write');
  });
  after(async () => {
    await fake.close();
  });

  it('answers a tag that is there with 200 and one that is not with 404', async () => {
    assert.equal((await call(fake, 'GET', '/repos/o/r/tags/v1')).status, 200);
    assert.equal((await call(fake, 'GET', '/repos/o/r/tags/v2')).status, 404);
  });

  it('creates a milestone with 201, refuses a field the definition does not name, and sets it on an issue, refusing one that is not there', async () => {
    assert.equal((await call(fake, 'POST', '/repos/o/r/milestones', { title: 'x', bogus: 1 })).status, 422);
    const made = await call(fake, 'POST', '/repos/o/r/milestones', { title: 'v1' });
    assert.equal(made.status, 201);
    const id = (made.json as { id: number }).id;
    const set = await call(fake, 'PATCH', '/repos/o/r/issues/1', { milestone: id });
    assert.equal(set.status, 201);
    assert.equal((set.json as { milestone: { title: string } }).milestone.title, 'v1');
    assert.equal((await call(fake, 'PATCH', '/repos/o/r/issues/1', { milestone: id + 1 })).status, 422);
    assert.equal(((await call(fake, 'GET', '/repos/o/r/milestones?state=all')).json as unknown[]).length, 1);
  });

  it('puts comments and events on the timeline in the order they happened, and pages it', async () => {
    fake.addComment('o/r', 1, 'writer', 'a comment');
    await call(fake, 'PATCH', '/repos/o/r/issues/1', { state: 'closed' });
    await call(fake, 'PATCH', '/repos/o/r/issues/1', { state: 'open' });
    const timeline = (await call(fake, 'GET', '/repos/o/r/issues/1/timeline')).json as { type: string }[];
    assert.deepEqual(timeline.map((entry) => entry.type), ['milestone', 'comment', 'close', 'reopen']);
    const page = await call(fake, 'GET', '/repos/o/r/issues/1/timeline?page=2&limit=3');
    assert.equal((page.json as unknown[]).length, 1);
    assert.equal(page.headers.get('x-total-count'), '1', 'Forgejo v17.0.0 counts the page here, not the timeline');
    const past = await call(fake, 'GET', '/repos/o/r/issues/1/timeline?page=3&limit=3');
    assert.equal(past.json, null, 'Forgejo v17.0.0 answers a page past the end of the timeline with null');
    assert.equal(past.headers.get('x-total-count'), '0');
  });

  it('answers the permission of a known account, and 404 for one it never heard of', async () => {
    assert.deepEqual((await call(fake, 'GET', '/repos/o/r/collaborators/writer/permission')).json, { permission: 'write', role_name: 'write', user: { login: 'writer', id: 6, full_name: '', email: '', avatar_url: '' } });
    assert.equal((await call(fake, 'GET', '/repos/o/r/collaborators/nobody/permission')).status, 404);
  });

  it('answers the combined status as queued, and an empty object when nothing was queued', async () => {
    assert.deepEqual((await call(fake, 'GET', '/repos/o/r/commits/abc/status')).json, {});
    fake.setChecks('o/r', ['pending', 'success']);
    assert.equal(((await call(fake, 'GET', '/repos/o/r/commits/abc/status')).json as { state: string }).state, 'pending');
    assert.equal(((await call(fake, 'GET', '/repos/o/r/commits/abc/status')).json as { state: string }).state, 'success');
    assert.equal(((await call(fake, 'GET', '/repos/o/r/commits/abc/status')).json as { state: string }).state, 'success');
  });
});
