import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import { clientFor, startFakeForgejo } from '../testing/fake-forgejo.mts';
import type { FakeForgejo } from '../testing/fake-forgejo.mts';
import { addBlocker, listBlockers, removeBlocker } from './dependencies.mts';
import { UsageError } from './refusals.mts';

describe('native blocked-by relations', () => {
  let fake: FakeForgejo;
  const blocked = { owner: 'o', repo: 'r', number: 1 };
  const blocker = { owner: 'o', repo: 'r', number: 2 };
  const elsewhere = { owner: 'p', repo: 's', number: 1 };
  before(async () => {
    fake = await startFakeForgejo();
    fake.addRepository('o/r');
    fake.addRepository('p/s');
    fake.addIssue('o/r', { title: 'Blocked, so that it waits' });
    fake.addIssue('o/r', { title: 'Blocker, so that it blocks' });
    fake.addIssue('p/s', { title: 'Elsewhere, so that it is another repository' });
  });
  after(async () => {
    await fake.close();
  });

  it('writes the relation to the blocked issue with the blocker in the body, and the blocker gains nothing (planted: reversed)', async () => {
    const api = clientFor(fake);
    await addBlocker(api, blocked, blocker);
    assert.deepEqual(fake.readIssue('o/r', 1).dependencies, ['o/r#2']);
    assert.deepEqual(fake.readIssue('o/r', 2).dependencies, []);
    const post = fake.requests.find((request) => request.method === 'POST' && request.path === '/repos/o/r/issues/1/dependencies');
    assert.deepEqual(post?.body, { owner: 'o', repo: 'r', index: 2 });
    assert.deepEqual(await listBlockers(api, blocked), [blocker]);
    assert.deepEqual(await listBlockers(api, blocker), []);
  });

  it('records a relation across repositories (innocent case)', async () => {
    await addBlocker(clientFor(fake), blocked, elsewhere);
    assert.deepEqual(fake.readIssue('o/r', 1).dependencies.sort(), ['o/r#2', 'p/s#1']);
  });

  it('refuses a self dependency before it sends anything', async () => {
    const writes = fake.writes().length;
    await assert.rejects(addBlocker(clientFor(fake), blocked, blocked), UsageError);
    assert.equal(fake.writes().length, writes);
  });

  it('removes exactly the relation named and keeps the others', async () => {
    assert.equal(await removeBlocker(clientFor(fake), blocked, elsewhere), true);
    assert.deepEqual(fake.readIssue('o/r', 1).dependencies, ['o/r#2']);
  });

  it('reports a removal of nothing and sends no DELETE for it', async () => {
    const deletes = fake.requests.filter((request) => request.method === 'DELETE').length;
    assert.equal(await removeBlocker(clientFor(fake), blocked, elsewhere), false);
    assert.equal(fake.requests.filter((request) => request.method === 'DELETE').length, deletes);
  });
});
