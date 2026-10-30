import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, describe, it } from 'node:test';
import { UsageError } from '../domain/refusals.mts';
import { FAKE_TOKEN, contextFor, seedLabels, startFakeForgejo } from '../testing/fake-forgejo.mts';
import type { FakeForgejo } from '../testing/fake-forgejo.mts';
import { git } from '../testing/git-fixture.mts';
import * as issueList from './issue-list.mts';

const FIRST = 'o/r#1\timplementing\tP1\tGate waits for a stale neighbour';
const SECOND = 'o/r#2\tdone\tP2\tGate waits for a copy of the checkout';
const THIRD = 'o/r#3\tready\t-\tRename the colour palette';
const FOURTH = 'o/r#4\t-\t-\tNothing about it in the title';
const OTHER = 'o/other#1\tplanned\tP3\tGate flakes in the other repository';

describe('issue-list', () => {
  let fake: FakeForgejo;
  let checkout: string;
  const directory = mkdtempSync(join(tmpdir(), 'forgejo-issue-list-'));
  before(async () => {
    fake = await startFakeForgejo({ pageMaximum: 2 });
    for (const repository of ['o/r', 'o/other', 'p/foreign']) fake.addRepository(repository);
    seedLabels(fake, 'o');
    seedLabels(fake, 'p');
    fake.addIssue('o/r', { title: 'Gate waits for a stale neighbour', labels: ['status/implementing', 'priority/p1'] });
    fake.addIssue('o/r', { title: 'Gate waits for a copy of the checkout', state: 'closed', labels: ['status/done', 'priority/p2'] });
    fake.addIssue('o/r', { title: 'Rename the colour palette', body: 'Nothing that concerns the checks.', labels: ['status/ready'] });
    fake.addIssue('o/r', { title: 'Nothing about it in the title', body: 'The GATE also waits here.' });
    fake.addIssue('o/other', { title: 'Gate flakes in the other repository', labels: ['status/planned', 'priority/p3'] });
    fake.addIssue('p/foreign', { title: 'Gate of another owner', labels: ['status/ready'] });
    checkout = join(directory, 'checkout');
    git(directory, 'init', '-q', checkout);
    git(checkout, 'remote', 'add', 'origin', 'https://forge.example.test/o/r.git');
  });
  after(async () => {
    await fake.close();
    rmSync(directory, { recursive: true, force: true });
  });

  const list = async (...args: string[]): Promise<string[]> => {
    const result = await issueList.run(args, contextFor(fake, { cwd: checkout }));
    assert.equal(result.exitCode, 0);
    assert.equal(result.stderr, '');
    return result.stdout === '' ? [] : result.stdout.trimEnd().split('\n');
  };

  it('lists the open issues of the repository the checkout names, one line each, when nothing narrows it (innocent case)', async () => {
    assert.deepEqual(await list(), [FIRST, THIRD, FOURTH]);
  });

  it('keeps the matching open issues and leaves out the matching closed one, the innocent one and the other repository (planted)', async () => {
    assert.deepEqual(await list('--search', 'gate'), [FIRST, FOURTH]);
  });

  it('lists the matching closed issue and no open one for --state closed (planted)', async () => {
    assert.deepEqual(await list('--state', 'closed', '--search', 'gate'), [SECOND]);
  });

  it('lists the matching open and closed issues for --state all, and the innocent one only without a search (planted)', async () => {
    assert.deepEqual(await list('--state', 'all', '--search', 'gate'), [FIRST, SECOND, FOURTH]);
    assert.deepEqual(await list('--state', 'all'), [FIRST, SECOND, THIRD, FOURTH]);
  });

  it('wants every word of the text, in any order', async () => {
    assert.deepEqual(await list('--state', 'all', '--search', 'gate stale'), [FIRST]);
    assert.deepEqual(await list('--state', 'all', '--search', 'stale   gate'), [FIRST]);
    assert.deepEqual(await list('--state', 'all', '--search', 'gate nonexistent'), []);
  });

  it('names the repository without reading the checkout, and reads no other repository of the owner', async () => {
    const result = await issueList.run(['o/other', '--search', 'gate'], contextFor(fake, { cwd: directory }));
    assert.equal(result.stdout, `${OTHER}\n`);
  });

  it('lists every repository of the owner for --owner, in the order of repository and number, and no other owner (planted)', async () => {
    assert.deepEqual(await list('--owner', 'o', '--search', 'gate'), [OTHER, FIRST, FOURTH]);
    assert.deepEqual(await list('--owner', 'p', '--search', 'gate'), ['p/foreign#1\tready\t-\tGate of another owner']);
  });

  it('sends every word as a quoted term, so that no operator of the search is read in it (planted: operators, quotes and a backslash)', async () => {
    await list('--search', 'is:closed -stale say "hi" \\');
    const search = fake.requests.filter((request) => request.path === '/repos/issues/search').at(-1);
    assert.equal(search?.query.q, '"is:closed" "-stale" "say" "\\"hi\\"" "\\\\"');
    assert.equal(search?.query.state, 'open');
  });

  it('reads every page of a long answer', async () => {
    assert.equal((await list('--state', 'all', '--owner', 'o')).length, 5);
  });

  it('refuses what it cannot read as asked, before it asks Forgejo anything', async () => {
    const before = fake.requests.length;
    const context = contextFor(fake, { cwd: checkout });
    for (const args of [
      ['--state', 'maybe'],
      ['--search', '  '],
      ['--owner', 'o', 'o/r'],
      ['--owner', 'not a name'],
      ['--label', 'status/ready'],
      ['--state'],
      ['a-name-that-is-no-repository'],
      ['o/r', 'o/other'],
    ]) {
      await assert.rejects(issueList.run(args, context), UsageError, args.join(' '));
    }
    assert.equal(fake.requests.length, before);
  });

  it('only reads, and prints neither the token nor anything of it', async () => {
    const result = await issueList.run(['--state', 'all'], contextFor(fake, { cwd: checkout }));
    assert.ok(!result.stdout.includes(FAKE_TOKEN) && !result.stderr.includes(FAKE_TOKEN));
    assert.ok(fake.requests.length > 0);
    assert.deepEqual(fake.writes(), []);
  });
});
