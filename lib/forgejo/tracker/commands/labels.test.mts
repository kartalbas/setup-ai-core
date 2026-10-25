import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, beforeEach, describe, it } from 'node:test';
import { PreconditionError, UsageError } from '../domain/refusals.mts';
import { contextFor, seedLabels, startFakeForgejo } from '../testing/fake-forgejo.mts';
import type { FakeForgejo } from '../testing/fake-forgejo.mts';
import * as issueDependency from './issue-dependency.mts';
import * as issueLabel from './issue-label.mts';
import * as issueStatus from './issue-status.mts';
import * as labelsSync from './labels-sync.mts';
import type { CommandContext } from './command.mts';

let fake: FakeForgejo;
let context: CommandContext;
const directory = mkdtempSync(join(tmpdir(), 'forgejo-labels-'));

before(async () => {
  fake = await startFakeForgejo();
  fake.addRepository('o/r');
  fake.addRepository('p/s');
  seedLabels(fake, 'o');
  context = contextFor(fake);
});
after(async () => {
  await fake.close();
  rmSync(directory, { recursive: true, force: true });
});

describe('issue-label', () => {
  let number: number;
  beforeEach(() => {
    number = fake.addIssue('o/r', { title: 'Labelled, so that it has labels', labels: ['status/ready', 'priority/p1', 'type/feature', 'area/gate', 'needs:owner'] });
  });

  it('adds a label of the non-exclusive family and keeps every other label (innocent case)', async () => {
    await issueLabel.runLabel(['o/r', String(number), '--add', 'area:docs'], context);
    assert.deepEqual(fake.readIssue('o/r', number).labels.sort(), ['area/docs', 'area/gate', 'needs:owner', 'priority/p1', 'status/ready', 'type/feature']);
  });

  it('removes one label and keeps the others', async () => {
    await issueLabel.runLabel(['o/r', String(number), '--remove', 'needs:owner'], context);
    assert.deepEqual(fake.readIssue('o/r', number).labels.sort(), ['area/gate', 'priority/p1', 'status/ready', 'type/feature']);
  });

  it('replaces the type and touches no other family', async () => {
    await issueLabel.runLabel(['o/r', String(number), '--replace', 'type:bug'], context);
    assert.deepEqual(fake.readIssue('o/r', number).labels.sort(), ['area/gate', 'needs:owner', 'priority/p1', 'status/ready', 'type/bug']);
  });

  it('refuses a second label of an exclusive family and writes nothing (planted: two types)', async () => {
    const writes = fake.writes().length;
    await assert.rejects(issueLabel.runLabel(['o/r', String(number), '--add', 'type/bug'], context), /use --replace/);
    await assert.rejects(issueLabel.runLabel(['o/r', String(number), '--add', 'type/bug', '--add', 'type/feature'], context), UsageError);
    assert.equal(fake.writes().length, writes);
  });

  it('refuses an unknown label, and sends the status and priority labels to their commands', async () => {
    await assert.rejects(issueLabel.runLabel(['o/r', String(number), '--add', 'area/nonexistent'], context), /has no label area\/nonexistent/);
    await assert.rejects(issueLabel.runLabel(['o/r', String(number), '--replace', 'status/done'], context), /issue-status/);
    await assert.rejects(issueLabel.runLabel(['o/r', String(number), '--add', 'priority/p0'], context), /issue-priority/);
  });

  it('never replaces the whole set with a PUT', async () => {
    assert.ok(fake.requests.every((request) => request.method !== 'PUT'));
  });
});

describe('issue-priority and issue-status', () => {
  let number: number;
  beforeEach(() => {
    number = fake.addIssue('o/r', { title: 'Prioritized, so that it ranks', labels: ['status/ready', 'priority/p1', 'area/gate'] });
  });

  it('changes only the priority', async () => {
    await issueLabel.runPriority(['o/r', String(number), 'P2'], context);
    assert.deepEqual(fake.readIssue('o/r', number).labels.sort(), ['area/gate', 'priority/p2', 'status/ready']);
    await assert.rejects(issueLabel.runPriority(['o/r', String(number), 'P5'], context), UsageError);
  });

  it('sets the priority of several issues at once, as the Bash command does (planted: one number only before #340)', async () => {
    const other = fake.addIssue('o/r', { title: 'Ranked along, so that both rank', labels: ['status/ready', 'priority/p1'] });
    await issueLabel.runPriority(['o/r', String(number), String(other), 'P3'], context);
    assert.deepEqual([number, other].map((n) => fake.readIssue('o/r', n).labels.filter((label) => label.startsWith('priority/'))), [['priority/p3'], ['priority/p3']]);
  });

  it('changes no priority when one of several issues does not exist (planted)', async () => {
    await assert.rejects(issueLabel.runPriority(['o/r', String(number), '99999', 'P3'], context));
    assert.deepEqual(fake.readIssue('o/r', number).labels.filter((label) => label.startsWith('priority/')), ['priority/p1']);
  });

  it('changes only the status of an open issue', async () => {
    await issueStatus.run(['o/r', String(number), 'implementing'], context);
    assert.deepEqual(fake.readIssue('o/r', number).labels.sort(), ['area/gate', 'priority/p1', 'status/implementing']);
  });

  it('sends done to issue-proof and not-planned to issue-close', async () => {
    await assert.rejects(issueStatus.run(['o/r', String(number), 'done'], context), (error: unknown) => error instanceof PreconditionError && /issue-proof/.test(error.message));
    await assert.rejects(issueStatus.run(['o/r', String(number), 'not-planned'], context), (error: unknown) => error instanceof PreconditionError && /issue-close/.test(error.message));
    await assert.rejects(issueStatus.run(['o/r', String(number), 'finished'], context), UsageError);
  });

  it('refuses a status for a closed issue', async () => {
    const closed = fake.addIssue('o/r', { title: 'Closed, so that it is done', state: 'closed', labels: ['status/not-planned'] });
    await assert.rejects(issueStatus.run(['o/r', String(closed), 'ready'], context), /issue-reopen/);
  });

  it('moves several issues at once, as the Bash command does (planted: one number only before #340)', async () => {
    const other = fake.addIssue('o/r', { title: 'Moved along, so that both travel', labels: ['status/ready'] });
    const result = await issueStatus.run(['o/r', String(number), String(other), 'planned'], context);
    assert.deepEqual([number, other].map((n) => fake.readIssue('o/r', n).labels.filter((label) => label.startsWith('status/'))), [['status/planned'], ['status/planned']]);
    assert.equal(result.stdout.trim().split('\n').length, 2);
  });

  it('changes no issue when a closed one is among them (planted)', async () => {
    const closed = fake.addIssue('o/r', { title: 'Closed, so that it stops the move', state: 'closed', labels: ['status/not-planned'] });
    await assert.rejects(issueStatus.run(['o/r', String(number), String(closed), 'planned'], context), /issue-reopen/);
    assert.deepEqual(fake.readIssue('o/r', number).labels.filter((label) => label.startsWith('status/')), ['status/ready']);
  });
});

describe('issue-block and issue-unblock', () => {
  let blocked: number;
  let blocker: number;
  let elsewhere: number;
  beforeEach(() => {
    blocked = fake.addIssue('o/r', { title: 'Blocked, so that it waits' });
    blocker = fake.addIssue('o/r', { title: 'Blocker, so that it blocks' });
    elsewhere = fake.addIssue('p/s', { title: 'Elsewhere, so that it is another repository' });
  });

  it('names the blocked issue first (planted: reversed arguments give the reversed relation)', async () => {
    await issueDependency.runBlock(['o/r', String(blocked), 'o/r', String(blocker)], context);
    assert.deepEqual(fake.readIssue('o/r', blocked).dependencies, [`o/r#${blocker}`]);
    assert.deepEqual(fake.readIssue('o/r', blocker).dependencies, []);
  });

  it('blocks across repositories and unblocks only the relation named', async () => {
    await issueDependency.runBlock(['o/r', String(blocked), 'o/r', String(blocker)], context);
    await issueDependency.runBlock(['o/r', String(blocked), 'p/s', String(elsewhere)], context);
    const result = await issueDependency.runUnblock(['o/r', String(blocked), 'p/s', String(elsewhere)], context);
    assert.match(result.stdout, /is no longer blocked by p\/s#/);
    assert.deepEqual(fake.readIssue('o/r', blocked).dependencies, [`o/r#${blocker}`]);
  });

  it('reports a removal of nothing and exits 0', async () => {
    const result = await issueDependency.runUnblock(['o/r', String(blocked), 'o/r', String(blocker)], context);
    assert.equal(result.exitCode, 0);
    assert.match(result.stdout, /nothing removed/);
  });

  it('refuses a self dependency and an incomplete address, before any request', async () => {
    const before = fake.requests.length;
    await assert.rejects(issueDependency.runBlock(['o/r', String(blocked), 'o/r', String(blocked)], context), UsageError);
    await assert.rejects(issueDependency.runBlock(['o/r', String(blocked), String(blocker)], context), UsageError);
    assert.equal(fake.requests.length, before);
    assert.deepEqual(fake.readIssue('o/r', blocked).dependencies, []);
  });
});

describe('labels-sync', () => {
  const catalog = 'type\ttype:bug\tD73A4A\tA mechanism that misbehaves\narea\tarea:gate\t1D76DB\tThe gate\ncloses\tcloses:test\t0E8A16\tCloses on a test\n';
  let syncContext: CommandContext;
  before(() => {
    fake.addRepository('q/t');
    fake.addLabel('q', { name: 'placeholder' });
    const path = join(directory, 'labels.tsv');
    writeFileSync(path, catalog);
    syncContext = { ...context, settings: { ...context.settings, labelsFile: path } };
  });

  it('creates the families with their exclusivity, and the status and priority labels', async () => {
    const result = await labelsSync.run(['--org', 'q'], syncContext);
    assert.equal(result.exitCode, 0);
    const byName = new Map(fake.listLabels('q').map((label) => [label.name, label]));
    assert.equal(byName.get('type/bug')?.exclusive, true);
    assert.equal(byName.get('area/gate')?.exclusive, false);
    assert.equal(byName.get('closes:test')?.exclusive, false);
    assert.equal(byName.get('status/not-planned')?.exclusive, true);
    assert.equal(byName.get('priority/p9')?.exclusive, true);
    assert.match(result.stdout, /not in the catalog, left alone: placeholder/);
    assert.ok(byName.has('placeholder'));
  });

  it('writes nothing the second time (innocent case) and checks without writing', async () => {
    const writes = fake.writes().length;
    const again = await labelsSync.run(['--org', 'q'], syncContext);
    assert.match(again.stdout, /0 to create, 0 to update/);
    const checked = await labelsSync.run(['--org', 'q', '--check'], syncContext);
    assert.equal(checked.exitCode, 0);
    assert.equal(fake.writes().length, writes);
  });

  it('updates a label that differs, and --check reports the difference with exit 1 and writes nothing', async () => {
    writeFileSync(join(directory, 'labels.tsv'), catalog.replace('The gate', 'The gate, changed'));
    const writes = fake.writes().length;
    const checked = await labelsSync.run(['--org', 'q', '--check'], syncContext);
    assert.equal(checked.exitCode, 1);
    assert.match(checked.stdout, /update area\/gate \(description\)/);
    assert.equal(fake.writes().length, writes);
    await labelsSync.run(['--org', 'q'], syncContext);
    assert.equal(fake.listLabels('q').find((label) => label.name === 'area/gate')?.description, 'The gate, changed');
  });

  it('makes no write when the last row is bad (planted: a bad last row)', async () => {
    writeFileSync(join(directory, 'labels.tsv'), `${catalog}area\tarea:docs\tZZZZZZ\tDocs\n`);
    const writes = fake.writes().length;
    await assert.rejects(labelsSync.run(['--org', 'q'], syncContext), /labels\.tsv:4 has 'ZZZZZZ'/);
    assert.equal(fake.writes().length, writes);
  });

  it('refuses an email address in the catalog and a run without the labels file', async () => {
    writeFileSync(join(directory, 'labels.tsv'), `${catalog}area\tarea:docs\t1D76DB\tWrite to jane@corp.com\n`);
    await assert.rejects(labelsSync.run(['--org', 'q'], syncContext), PreconditionError);
    await assert.rejects(labelsSync.run(['--org', 'q'], context), UsageError);
  });
});
