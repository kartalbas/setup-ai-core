import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import { ContractError, ForgejoClient, PermissionError } from '../api/client.mts';
import { createTokenSource } from '../api/credentials.mts';
import { UsageError } from '../domain/refusals.mts';
import { GitClient } from '../git/git.mts';
import { contextFor, seedLabels, startFakeForgejo } from '../testing/fake-forgejo.mts';
import type { FakeForgejo } from '../testing/fake-forgejo.mts';
import * as doctor from './doctor.mts';
import * as issueMine from './issue-mine.mts';
import * as issueThread from './issue-thread.mts';
import * as status from './status.mts';

describe('issue-thread', () => {
  let fake: FakeForgejo;
  before(async () => {
    fake = await startFakeForgejo();
    fake.addRepository('o/r');
    seedLabels(fake, 'o');
    fake.addIssue('o/r', { title: 'Threaded, so that it has comments', body: 'The body', labels: ['status/ready', 'area/gate'] });
    fake.addComment('o/r', 1, 'someone', 'First comment');
    fake.addComment('o/r', 1, 'someone-else', 'Second comment');
    fake.addIssue('o/r', { title: 'Bare, so that it has no labels' });
  });
  after(async () => {
    await fake.close();
  });

  it('prints the JSON the GitHub part prints, on one line', async () => {
    const result = await issueThread.run(['o/r', '1', '--json'], contextFor(fake));
    assert.equal(result.stdout.trim().split('\n').length, 1);
    const thread = JSON.parse(result.stdout) as Record<string, unknown>;
    assert.equal(thread.number, 1);
    assert.equal(thread.state, 'open');
    assert.deepEqual(thread.labels, ['status/ready', 'area/gate']);
    assert.equal(thread.body, 'The body');
    assert.deepEqual((thread.comments as { author: string; body: string }[]).map((comment) => [comment.author, comment.body]), [['someone', 'First comment'], ['someone-else', 'Second comment']]);
  });

  it('lays the thread out for a person', async () => {
    const result = await issueThread.run(['o/r', '1'], contextFor(fake));
    const text = result.stdout.split('\n');
    assert.equal(text[0], '#1 Threaded, so that it has comments');
    assert.equal(text[1], 'state: open');
    assert.equal(text[2], 'labels: status/ready, area/gate');
    assert.ok(result.stdout.includes('--- someone '));
    assert.match((await issueThread.run(['o/r', '2'], contextFor(fake))).stdout, /labels: -\n/);
  });

  it('refuses a thread shorter than the issue states (planted)', async () => {
    fake.fail({ path: '/repos/o/r/issues/1/comments', mode: { kind: 'truncate-list' } });
    await assert.rejects(issueThread.run(['o/r', '1', '--json'], contextFor(fake)), ContractError);
  });
});

describe('issue-mine', () => {
  let fake: FakeForgejo;
  before(async () => {
    fake = await startFakeForgejo();
    fake.addRepository('o/r');
    fake.addIssue('o/r', { title: 'Mine, so that it is taken', assignees: ['fake-user'] });
    fake.addIssue('o/r', { title: 'Theirs, so that it is refused', assignees: ['someone'] });
    fake.addIssue('o/r', { title: 'Nobody, so that it is open to all' });
  });
  after(async () => {
    await fake.close();
  });

  it('exits 0 for an issue assigned to the signed-in account (innocent case)', async () => {
    const result = await issueMine.run(['o/r', '1'], contextFor(fake));
    assert.equal(result.exitCode, 0);
    assert.match(result.stdout, /o\/r#1 is assigned to @fake-user\./);
  });

  it('exits 1 with a REFUSED line for somebody else and for nobody', async () => {
    const theirs = await issueMine.run(['o/r', '2'], contextFor(fake));
    assert.equal(theirs.exitCode, 1);
    assert.match(theirs.stdout, /^REFUSED: o\/r#2 is assigned to @someone, not to @fake-user/);
    const nobody = await issueMine.run(['o/r', '3'], contextFor(fake));
    assert.equal(nobody.exitCode, 1);
    assert.match(nobody.stdout, /is assigned to nobody/);
  });

  it('fails when the signed-in account cannot be read, and never says "assigned to nobody" (planted: 403 on /user)', async () => {
    const restricted = await startFakeForgejo({ userScopeMissing: true });
    restricted.addRepository('o/r');
    restricted.addIssue('o/r', { title: 'Unassigned, so that the read matters' });
    try {
      await assert.rejects(issueMine.run(['o/r', '1'], contextFor(restricted)), (error: unknown) => error instanceof PermissionError && /read:user/.test(error.message));
    } finally {
      await restricted.close();
    }
  });
});

describe('status', () => {
  let fake: FakeForgejo;
  before(async () => {
    fake = await startFakeForgejo({ pageMaximum: 30 });
    for (const repository of ['o/one', 'o/two', 'p/three', 'o/outside']) fake.addRepository(repository);
    seedLabels(fake, 'o');
    seedLabels(fake, 'p');
    fake.addIssue('o/one', { title: 'A, so that it has both labels', labels: ['status/ready', 'area/gate', 'priority/p1'] });
    fake.addIssue('o/one', { title: 'B, so that it has one label', labels: ['status/ready'] });
    fake.addIssue('o/one', { title: 'C, so that it has the other label', labels: ['area/gate', 'status/implementing'] });
    fake.addIssue('o/two', { title: 'D, so that it is another repository', labels: ['status/ready', 'area/gate'] });
    fake.addIssue('p/three', { title: 'E, so that it is another owner', labels: ['status/ready', 'area/gate'] });
    fake.addIssue('o/outside', { title: 'F, so that it is no clone of the project', labels: ['status/ready', 'area/gate'] });
    fake.addIssue('o/one', { title: 'G, so that it is closed', state: 'closed', labels: ['status/done'] });
  });
  after(async () => {
    await fake.close();
  });

  const rows = async (...args: string[]): Promise<{ repository: string; number: number; status: string | null }[]> =>
    JSON.parse((await status.run([...args, '--json'], contextFor(fake))).stdout) as { repository: string; number: number; status: string | null }[];

  it('lists the named repositories of several owners and no other (innocent case)', async () => {
    const found = await rows('o/one', 'o/two', 'p/three');
    assert.deepEqual(found.map((row) => `${row.repository}#${row.number}`).sort(), ['o/one#1', 'o/one#2', 'o/one#3', 'o/two#1', 'p/three#1']);
  });

  it('keeps an issue only when it carries every label asked for (planted: any-versus-all)', async () => {
    const both = await rows('o/one', 'o/two', '--label', 'status:ready', '--label', 'area:gate');
    assert.deepEqual(both.map((row) => `${row.repository}#${row.number}`).sort(), ['o/one#1', 'o/two#1']);
    const either = await rows('o/one', '--label', 'status/ready');
    assert.equal(either.length, 2);
  });

  it('filters by state', async () => {
    assert.deepEqual((await rows('o/one', '--state', 'closed')).map((row) => row.number), [4]);
    assert.equal((await rows('o/one', '--state', 'all')).length, 4);
    await assert.rejects(status.run(['o/one', '--state', 'maybe'], contextFor(fake)), UsageError);
  });

  it('reads every page, also past the cap of the server', async () => {
    for (let n = 0; n < 70; n++) fake.addIssue('o/two', { title: `Many ${n}, so that there are pages`, labels: ['status/backlog'] });
    assert.equal((await rows('o/two')).length, 71);
  });

  it('refuses a list that lost an item of a page (planted: a missing item)', async () => {
    fake.fail({ path: '/repos/issues/search', mode: { kind: 'truncate-list' } });
    await assert.rejects(status.run(['o/two', '--json'], contextFor(fake)), (error: unknown) => error instanceof ContractError && /announced/.test(error.message));
  });

  it('prints the text form and says what it reports', async () => {
    const result = await status.run(['o/one'], contextFor(fake));
    assert.match(result.stdout, /^o\/one\n {2}#1 \[ready p1\] A, so that it has both labels\n/);
    assert.match(result.stdout, /\d+ issues? as the tracker records them\n$/);
  });

  it('takes the repositories of the clones beside the checkout when none is named', async () => {
    class NeighbourGit extends GitClient {
      override listCloneOrigins(): Promise<{ owner: string; repo: string }[]> {
        return Promise.resolve([{ owner: 'p', repo: 'three' }]);
      }
    }
    const clones = contextFor(fake, { git: new NeighbourGit() });
    const found = JSON.parse((await status.run(['--json'], clones)).stdout) as { repository: string }[];
    assert.deepEqual(found.map((row) => row.repository), ['p/three']);
  });
});

describe('doctor', () => {
  let fake: FakeForgejo;
  before(async () => {
    fake = await startFakeForgejo();
  });
  after(async () => {
    await fake.close();
  });

  it('says the tracker is not configured when a setting is missing', async () => {
    const context = contextFor(fake, { settings: { forgejoUrl: undefined, tokenCommand: undefined, labelsFile: undefined } });
    const result = await doctor.run([], context);
    assert.equal(result.exitCode, 1);
    assert.match(result.stdout, /^problem: the Forgejo tracker is not configured: FORGEJO_URL and FORGEJO_TOKEN_COMMAND are not set/);
  });

  it('says healthy when Forgejo knows the token (innocent case)', async () => {
    const result = await doctor.run([], contextFor(fake));
    assert.equal(result.exitCode, 0);
    assert.match(result.stdout, /^ok: Forgejo at http:\/\/127\.0\.0\.1:\d+ knows the token as fake-user/);
  });

  it('says not authorized when Forgejo refuses the token', async () => {
    const wrong = new ForgejoClient({ baseUrl: fake.url, token: createTokenSource("printf '%s' wrong") });
    const result = await doctor.run([], contextFor(fake, { api: () => wrong }));
    assert.equal(result.exitCode, 1);
    assert.match(result.stdout, /^problem: not authorized: Forgejo does not accept the token/);
  });

  it('says not authorized, and names the scope, when the token lacks read:user', async () => {
    const restricted = await startFakeForgejo({ userScopeMissing: true });
    try {
      const result = await doctor.run([], contextFor(restricted));
      assert.equal(result.exitCode, 1);
      assert.match(result.stdout, /not authorized: the token cannot read its own user; it needs the scope read:user/);
    } finally {
      await restricted.close();
    }
  });

  it('says not authorized when the token command fails, without printing what it said', async () => {
    const failing = new ForgejoClient({ baseUrl: fake.url, token: createTokenSource('echo secret-in-output; exit 3') });
    const result = await doctor.run([], contextFor(fake, { api: () => failing }));
    assert.match(result.stdout, /not authorized: read the Forgejo token: FORGEJO_TOKEN_COMMAND exited with status 3/);
    assert.ok(!result.stdout.includes('secret-in-output'));
  });

  it('says Forgejo cannot be reached when nothing answers', async () => {
    const lonely = new ForgejoClient({ baseUrl: 'http://127.0.0.1:1', token: createTokenSource("printf '%s' t"), connectTimeoutMs: 500 });
    const result = await doctor.run([], contextFor(fake, { api: () => lonely }));
    assert.match(result.stdout, /^problem: Forgejo cannot be reached/);
  });
});
