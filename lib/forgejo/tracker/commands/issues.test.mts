import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, beforeEach, describe, it } from 'node:test';
import { PartialCompletionError, TransportError } from '../api/client.mts';
import { PreconditionError, UsageError } from '../domain/refusals.mts';
import { contextFor, seedLabels, startFakeForgejo } from '../testing/fake-forgejo.mts';
import type { FakeForgejo } from '../testing/fake-forgejo.mts';
import { createGitFixture } from '../testing/git-fixture.mts';
import type { GitFixture } from '../testing/git-fixture.mts';
import * as issueAssign from './issue-assign.mts';
import * as issueComment from './issue-comment.mts';
import * as issueEdit from './issue-edit.mts';
import * as issueNew from './issue-new.mts';
import * as issueState from './issue-state.mts';
import type { CommandContext } from './command.mts';

let fake: FakeForgejo;
let context: CommandContext;
const directory = mkdtempSync(join(tmpdir(), 'forgejo-commands-'));

before(async () => {
  fake = await startFakeForgejo();
  fake.addRepository('o/r', { assignable: ['fake-user', 'second-user'] });
  fake.addRepository('o/hidden', { isPrivate: true });
  seedLabels(fake, 'o');
  context = contextFor(fake);
});
after(async () => {
  await fake.close();
  rmSync(directory, { recursive: true, force: true });
});

function file(name: string, content: string): string {
  const path = join(directory, name);
  writeFileSync(path, content);
  return path;
}

const ASKED = ['--asked-by', 'person', '--asked-in', 'the chat of 2026-10-23'];
function newArguments(...extra: string[]): string[] {
  return ['--repo', 'o/r', '--title', 'Do the thing, so that it is done', '--body-file', file('body.md', 'The body.\n'), '--label', 'type:feature', '--label', 'area:gate', '--priority', 'P1', ...extra];
}

describe('issue-new', () => {
  it('creates the issue with its labels, status and priority, and prints the number (innocent case)', async () => {
    const result = await issueNew.run([...newArguments(), ...ASKED], context);
    assert.equal(result.exitCode, 0);
    const number = Number(result.stdout.trim());
    const created = fake.readIssue('o/r', number);
    assert.deepEqual(created.labels.sort(), ['area/gate', 'priority/p1', 'status/ready', 'type/feature']);
    assert.equal(created.body.split('\n')[0], 'Asked for by @person on 2026-10-23 in the chat of 2026-10-23.');
    assert.ok(created.body.endsWith('The body.\n'));
  });

  it('takes --status and a defect found in the work', async () => {
    const args = newArguments('--status', 'backlog', '--found-in', 'issue o/r#1').map((value) => (value === 'type:feature' ? 'type:bug' : value));
    const result = await issueNew.run(args, context);
    const created = fake.readIssue('o/r', Number(result.stdout.trim()));
    assert.ok(created.labels.includes('status/backlog') && created.labels.includes('type/bug'));
    assert.match(created.body, /^Found in issue o\/r#1 on 2026-10-23, a defect filed without a yes\./);
  });

  const refusals: [string, string[]][] = [
    ['conflicting provenance', [...newArguments(), ...ASKED, '--found-in', 'x']],
    ['--found-in without a bug label', [...newArguments(), '--found-in', 'x']],
    ['no provenance', newArguments()],
    ['one label', ['--repo', 'o/r', '--title', 't', '--body-file', file('b.md', 'x'), '--label', 'type:bug', '--priority', 'P1', ...ASKED]],
    ['no priority', ['--repo', 'o/r', '--title', 't', '--body-file', file('b.md', 'x'), '--label', 'type:bug', '--label', 'area:gate', ...ASKED]],
    ['a bad priority', [...newArguments(), ...ASKED, '--priority', 'P5']],
    ['a status that closes', [...newArguments(), ...ASKED, '--status', 'done']],
    ['an unreadable body file', ['--repo', 'o/r', '--title', 't', '--body-file', join(directory, 'missing.md'), '--label', 'type:bug', '--label', 'area:gate', '--priority', 'P1', ...ASKED]],
    ['an unknown option', [...newArguments(), ...ASKED, '--assignee', 'x']],
    ['two labels of one exclusive family', [...newArguments('--label', 'type:bug'), ...ASKED]],
    ['a label of the status family beside the status', [...newArguments('--label', 'status/testing'), ...ASKED]],
  ];
  for (const [name, args] of refusals) {
    it(`refuses ${name} before any request`, async () => {
      const before = fake.requests.length;
      await assert.rejects(issueNew.run(args, context), UsageError);
      assert.equal(fake.requests.length, before);
    });
  }

  it('refuses a label the project does not hold, and makes no issue', async () => {
    const writes = fake.writes().length;
    await assert.rejects(issueNew.run([...newArguments().map((value) => (value === 'area:gate' ? 'area:nonexistent' : value)), ...ASKED], context), /has no label area\/nonexistent/);
    assert.equal(fake.writes().length, writes);
  });

  it('refuses a literal email address for a public repository and lets it into a private one', async () => {
    const withAddress = file('address.md', 'Write to jane@corp.com\n');
    const writes = fake.writes().length;
    await assert.rejects(issueNew.run([...newArguments().map((value) => (value.endsWith('body.md') ? withAddress : value)), ...ASKED], context), PreconditionError);
    assert.equal(fake.writes().length, writes);
    const result = await issueNew.run([...newArguments().map((value) => (value.endsWith('body.md') ? withAddress : value === 'o/r' ? 'o/hidden' : value)), ...ASKED], context);
    assert.equal(result.exitCode, 0);
  });
});

describe('issue-comment', () => {
  let number: number;
  beforeEach(() => {
    number = fake.addIssue('o/r', { title: 'Commented, so that it has a thread' });
  });

  it('adds one comment and prints its address (innocent case)', async () => {
    const result = await issueComment.run(['o/r', String(number), '--body-file', file('c.md', 'A comment')], context);
    assert.match(result.stdout, /^https:\/\/forge\.example\.test\/comment\/\d+\n$/);
    assert.deepEqual(fake.readIssue('o/r', number).comments, ['A comment']);
  });

  it('refuses an unreadable file and an empty comment before any request', async () => {
    const before = fake.requests.length;
    await assert.rejects(issueComment.run(['o/r', String(number), '--body-file', join(directory, 'nope.md')], context), UsageError);
    await assert.rejects(issueComment.run(['o/r', String(number), '--body-file', file('empty.md', '  \n')], context), UsageError);
    assert.equal(fake.requests.length, before);
  });

  it('refuses a literal email address for a public repository', async () => {
    await assert.rejects(issueComment.run(['o/r', String(number), '--body-file', file('mail.md', 'jane@corp.com')], context), PreconditionError);
    assert.deepEqual(fake.readIssue('o/r', number).comments, []);
  });

  it('reports a comment whose answer was lost as uncertain and sends it once (planted: lost answer)', async () => {
    fake.fail({ method: 'POST', path: `/repos/o/r/issues/${number}/comments`, mode: { kind: 'drop-after' } });
    await assert.rejects(issueComment.run(['o/r', String(number), '--body-file', file('lost.md', 'Lost answer')], context), (error: unknown) => error instanceof TransportError && error.uncertain);
    assert.equal(fake.requests.filter((request) => request.method === 'POST' && request.path === `/repos/o/r/issues/${number}/comments`).length, 1);
    assert.deepEqual(fake.readIssue('o/r', number).comments, ['Lost answer']);
  });

  it('finds the repository in the origin of the clone it runs in', async () => {
    const fixture: GitFixture = createGitFixture();
    try {
      const clone = fixture.clone(fixture.createRemote('o', 'r'), 'project', 'r');
      const result = await issueComment.run([String(number), '--body-file', file('here.md', 'From a clone')], { ...context, cwd: clone });
      assert.equal(result.exitCode, 0);
      assert.deepEqual(fake.readIssue('o/r', number).comments, ['From a clone']);
    } finally {
      fixture.dispose();
    }
  });
});

describe('issue-close and issue-reopen', () => {
  let number: number;
  beforeEach(() => {
    number = fake.addIssue('o/r', { title: 'Closed, so that it is finished', labels: ['status/implementing', 'area/gate', 'needs:owner'] });
  });

  it('closes as not planned: sets status/not-planned, closes, and keeps the other labels', async () => {
    const result = await issueState.runClose([`o/r`, String(number), '--reason', 'not-planned'], context);
    assert.match(result.stdout, new RegExp(`o/r#${number} closed as not planned`));
    const closed = fake.readIssue('o/r', number);
    assert.equal(closed.state, 'closed');
    assert.deepEqual(closed.labels.sort(), ['area/gate', 'needs:owner', 'status/not-planned']);
  });

  it('refuses to close as completed, names issue-proof, and sends nothing', async () => {
    const before = fake.requests.length;
    await assert.rejects(issueState.runClose(['o/r', String(number)], context), (error: unknown) => error instanceof PreconditionError && /issue-proof/.test(error.message));
    assert.equal(fake.requests.length, before);
    await assert.rejects(issueState.runClose(['o/r', String(number), '--reason', 'whatever'], context), UsageError);
  });

  it('reports a close that failed after the first issue as a partial completion that names the first', async () => {
    const second = fake.addIssue('o/r', { title: 'Second, so that it fails', labels: ['status/ready'] });
    fake.fail({ method: 'PATCH', path: `/repos/o/r/issues/${second}`, mode: { kind: 'status', status: 412, message: 'planted' } });
    await assert.rejects(issueState.runClose(['o/r', String(number), String(second), '--reason', 'not-planned'], context), (error: unknown) => error instanceof PartialCompletionError && error.completed.includes(`o/r#${number}`));
    assert.equal(fake.readIssue('o/r', number).state, 'closed');
  });

  it('reopens with an open status in place of the closing status', async () => {
    await issueState.runClose(['o/r', String(number), '--reason', 'not-planned'], context);
    await issueState.runReopen(['o/r', String(number), '--status', 'ready'], context);
    const reopened = fake.readIssue('o/r', number);
    assert.equal(reopened.state, 'open');
    assert.deepEqual(reopened.labels.sort(), ['area/gate', 'needs:owner', 'status/ready']);
  });

  it('refuses to reopen an open issue, a status that closes, and a missing status', async () => {
    await assert.rejects(issueState.runReopen(['o/r', String(number), '--status', 'ready'], context), PreconditionError);
    await assert.rejects(issueState.runReopen(['o/r', String(number), '--status', 'done'], context), UsageError);
    await assert.rejects(issueState.runReopen(['o/r', String(number)], context), UsageError);
  });
});

describe('issue-edit', () => {
  const origin = 'Asked for by @person on 2026-10-01 in the chat.';
  let number: number;
  beforeEach(() => {
    number = fake.addIssue('o/r', { title: 'Edited, so that it changes', body: `${origin}\n\nOld text` });
  });

  it('refuses an edit that changes nothing, before any request', async () => {
    const before = fake.requests.length;
    await assert.rejects(issueEdit.run(['o/r', String(number)], context), UsageError);
    assert.equal(fake.requests.length, before);
  });

  it('changes the title alone and leaves the body (innocent case)', async () => {
    await issueEdit.run(['o/r', String(number), '--title', 'Renamed, so that it reads well'], context);
    const edited = fake.readIssue('o/r', number);
    assert.equal(edited.title, 'Renamed, so that it reads well');
    assert.equal(edited.body, `${origin}\n\nOld text`);
  });

  it('puts the first line back when the new body drops it (planted: a body without the line)', async () => {
    const result = await issueEdit.run(['o/r', String(number), '--body-file', file('new.md', 'New text')], context);
    assert.equal(fake.readIssue('o/r', number).body, `${origin}\n\nNew text`);
    assert.match(result.stderr, /first line of the issue was kept/);
  });

  it('refuses a literal email address for a public repository', async () => {
    await assert.rejects(issueEdit.run(['o/r', String(number), '--body-file', file('mail2.md', 'jane@corp.com')], context), PreconditionError);
    assert.match(fake.readIssue('o/r', number).body, /Old text/);
  });
});

describe('issue-assign', () => {
  let number: number;
  beforeEach(() => {
    number = fake.addIssue('o/r', { title: 'Assigned, so that somebody owns it', assignees: ['fake-user'] });
  });

  it('adds one assignee and keeps the other', async () => {
    const result = await issueAssign.run(['o/r', String(number), '--add', 'second-user'], context);
    assert.deepEqual(fake.readIssue('o/r', number).assignees.sort(), ['fake-user', 'second-user']);
    assert.match(result.stdout, /assigned to fake-user, second-user/);
  });

  it('removes one assignee and keeps the other, and replaces the whole set', async () => {
    fake.addIssue('o/r', { title: 'Second, so that there are two', assignees: ['fake-user', 'second-user'] });
    await issueAssign.run(['o/r', String(number), '--add', 'second-user'], context);
    await issueAssign.run(['o/r', String(number), '--remove', 'fake-user'], context);
    assert.deepEqual(fake.readIssue('o/r', number).assignees, ['second-user']);
    await issueAssign.run(['o/r', String(number), '--replace', 'fake-user'], context);
    assert.deepEqual(fake.readIssue('o/r', number).assignees, ['fake-user']);
  });

  it('stops a login Forgejo does not offer before anything is written (planted: unknown login)', async () => {
    const writes = fake.writes().length;
    await assert.rejects(issueAssign.run(['o/r', String(number), '--add', 'stranger'], context), /does not offer stranger as an assignee/);
    assert.equal(fake.writes().length, writes);
    assert.deepEqual(fake.readIssue('o/r', number).assignees, ['fake-user']);
  });

  it('refuses contradictory and empty requests', async () => {
    await assert.rejects(issueAssign.run(['o/r', String(number), '--replace', 'fake-user', '--add', 'second-user'], context), UsageError);
    await assert.rejects(issueAssign.run(['o/r', String(number)], context), UsageError);
  });
});
