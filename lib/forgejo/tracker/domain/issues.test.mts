import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import { ContractError, NotFoundError, PartialCompletionError } from '../api/client.mts';
import { FAKE_HOST, clientFor, startFakeForgejo } from '../testing/fake-forgejo.mts';
import type { FakeForgejo } from '../testing/fake-forgejo.mts';
import {
  applyInOrder,
  composeOriginLine,
  getIssue,
  isOriginLine,
  keepOriginLine,
  parseIssueNumber,
  parseRepository,
  readComments,
  readThread,
  searchIssues,
  setAssignees,
} from './issues.mts';
import { UsageError } from './refusals.mts';

describe('the first line of a body', () => {
  it('names who asked, or where a defect or another finding was found', () => {
    assert.equal(composeOriginLine({ askedBy: '@person', askedIn: 'the chat' }, '2026-10-23'), 'Asked for by @person on 2026-10-23 in the chat.');
    assert.equal(composeOriginLine({ foundIn: 'issue-1', isDefect: true }, '2026-10-23'), 'Found in issue-1 on 2026-10-23, a defect filed without a yes.');
    assert.equal(composeOriginLine({ foundIn: 'issue-1', isDefect: false }, '2026-10-23'), 'Found in issue-1 on 2026-10-23, a finding filed without a yes.');
  });

  it('is recognized, and so is the address an issue was moved from', () => {
    assert.ok(isOriginLine('Asked for by @person on 2026-10-23 in the chat.'));
    assert.ok(isOriginLine(`https://${FAKE_HOST}/o/r/issues/12`));
    assert.ok(isOriginLine('Found in issue-1 on 2026-10-23, a defect filed without a yes.'));
    assert.ok(isOriginLine('Found in issue-1 on 2026-10-23, a finding filed without a yes.'));
    assert.ok(!isOriginLine('Found in the notes'));
    assert.ok(!isOriginLine('Some prose'));
  });

  it('is put back when an edit drops it (planted: a body without the line)', () => {
    const current = 'Asked for by @person on 2026-10-23 in the chat.\n\nOld text';
    const edited = keepOriginLine(current, 'New text');
    assert.equal(edited.kept, true);
    assert.equal(edited.body, 'Asked for by @person on 2026-10-23 in the chat.\n\nNew text');
  });

  it('is not doubled, and nothing is invented for an issue that has none (innocent cases)', () => {
    const current = 'Asked for by @person on 2026-10-23 in the chat.\n\nOld text';
    const own = 'Asked for by @person on 2026-10-23 in the chat.\n\nNew text';
    assert.deepEqual(keepOriginLine(current, own), { body: own, kept: false });
    assert.deepEqual(keepOriginLine('Plain old body', 'New text'), { body: 'New text', kept: false });
  });
});

describe('an issue address', () => {
  it('takes OWNER/REPO and a positive number only', () => {
    assert.deepEqual(parseRepository('o/r'), { owner: 'o', repo: 'r' });
    assert.throws(() => parseRepository('just-a-name'), UsageError);
    assert.equal(parseIssueNumber('12'), 12);
    for (const bad of ['0', '-1', '1.5', 'x', '']) assert.throws(() => parseIssueNumber(bad), UsageError);
  });
});

describe('reads and edits against the fake', () => {
  let fake: FakeForgejo;
  before(async () => {
    fake = await startFakeForgejo();
    fake.addRepository('o/r', { assignable: ['fake-user', 'second-user'] });
    fake.addLabel('o', { name: 'status/ready', exclusive: true });
    fake.addIssue('o/r', { title: 'First, so that there is one', body: 'Body one', labels: ['status/ready'] });
    fake.addComment('o/r', 1, 'someone', 'Comment one');
    fake.addComment('o/r', 1, 'someone-else', 'Comment two');
  });
  after(async () => {
    await fake.close();
  });

  it('reads an issue with its labels and assignees', async () => {
    const issue = await getIssue(clientFor(fake), { owner: 'o', repo: 'r', number: 1 });
    assert.equal(issue.title, 'First, so that there is one');
    assert.equal(issue.state, 'open');
    assert.deepEqual(issue.labels, ['status/ready']);
    assert.deepEqual(issue.assignees, []);
  });

  it('refuses a read of an issue that is not there, as an error and not an empty issue', async () => {
    await assert.rejects(getIssue(clientFor(fake), { owner: 'o', repo: 'r', number: 77 }), NotFoundError);
  });

  it('prints the thread in the JSON shape of the GitHub part, and the assignees', async () => {
    const thread = await readThread(clientFor(fake), { owner: 'o', repo: 'r', number: 1 });
    assert.deepEqual(Object.keys(thread).sort(), ['assignees', 'body', 'carriedFrom', 'comments', 'createdAt', 'labels', 'number', 'state', 'title']);
    assert.deepEqual(thread.comments.map((comment) => Object.keys(comment).sort()), [['author', 'body', 'created_at'], ['author', 'body', 'created_at']]);
    assert.deepEqual(thread.comments.map((comment) => comment.author), ['someone', 'someone-else']);
    assert.equal(thread.carriedFrom, null);
  });

  it('refuses a thread shorter than the comment count of the issue (planted: the list loses its last comment)', async () => {
    fake.fail({ path: '/repos/o/r/issues/1/comments', mode: { kind: 'truncate-list' } });
    await assert.rejects(readThread(clientFor(fake), { owner: 'o', repo: 'r', number: 1 }), (error: unknown) => error instanceof ContractError && /states 2 comments and Forgejo listed 1/.test(error.message));
    assert.equal((await readComments(clientFor(fake), { owner: 'o', repo: 'r', number: 1 }, 2)).length, 2);
  });

  it('sets the assignees as a whole and checks the answer', async () => {
    const issue = await setAssignees(clientFor(fake), { owner: 'o', repo: 'r', number: 1 }, ['fake-user', 'second-user']);
    assert.deepEqual([...issue.assignees].sort(), ['fake-user', 'second-user']);
    await assert.rejects(setAssignees(clientFor(fake), { owner: 'o', repo: 'r', number: 1 }, ['nobody-known']));
  });

  it('searches every page of an owner and names the repository of each issue', async () => {
    fake.addRepository('o/other');
    for (let n = 0; n < 55; n++) fake.addIssue('o/other', { title: `Other ${n}, so that there are pages` });
    const found = await searchIssues(clientFor(fake), 'o', 'open');
    assert.equal(found.filter((issue) => issue.repository.repo === 'other').length, 55);
    assert.equal(found.filter((issue) => issue.repository.repo === 'r').length, 1);
  });
});

describe('applying an action to several issues', () => {
  it('passes the first failure on as it is, because nothing was done', async () => {
    await assert.rejects(applyInOrder('close', [1, 2], String, () => Promise.reject(new Error('refused'))), /^Error: refused$/);
  });

  it('turns a later failure into a partial completion that names what was done', async () => {
    await assert.rejects(
      applyInOrder('close', [1, 2, 3], String, (item) => (item === 2 ? Promise.reject(new Error('refused')) : Promise.resolve())),
      (error: unknown) => error instanceof PartialCompletionError && error.completed.join() === '1' && /2 failed: refused/.test(error.message),
    );
  });

  it('does nothing wrong when every action succeeds (innocent case)', async () => {
    const seen: number[] = [];
    await applyInOrder('close', [1, 2], String, (item) => {
      seen.push(item);
      return Promise.resolve();
    });
    assert.deepEqual(seen, [1, 2]);
  });
});
