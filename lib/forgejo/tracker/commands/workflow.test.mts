import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { appendFileSync, chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { after, before, describe, it } from 'node:test';
import { PartialCompletionError } from '../api/client.mts';
import { composeLandedRecord, composeProvenRecord } from '../domain/workflow.mts';
import { parseRepository } from '../domain/issues.mts';
import { PreconditionError, UsageError } from '../domain/refusals.mts';
import { contextFor, FAKE_TOKEN, seedLabels, startFakeForgejo } from '../testing/fake-forgejo.mts';
import type { FakeForgejo } from '../testing/fake-forgejo.mts';
import { createGitFixture, git } from '../testing/git-fixture.mts';
import { createRecordingHarness } from '../testing/recording-harness.mts';
import type { RecordingHarness } from '../testing/recording-harness.mts';
import type { GitFixture } from '../testing/git-fixture.mts';
import { GitClient } from '../git/git.mts';
import { bashHarness } from '../harness.mts';
import type { CommandContext } from './command.mts';
import * as finishIssue from './finish-issue.mts';
import * as integrateIssue from './integrate-issue.mts';
import * as issueProof from './issue-proof.mts';
import * as issueRelease from './issue-release.mts';
import * as issueState from './issue-state.mts';
import * as startIssue from './start-issue.mts';

// The commits these tests make through GitClient need an identity, and a runner has none.
Object.assign(process.env, { GIT_AUTHOR_NAME: 'Example', GIT_AUTHOR_EMAIL: 'example@example.test', GIT_COMMITTER_NAME: 'Example', GIT_COMMITTER_EMAIL: 'example@example.test' });

const FAST = { integratePollSeconds: '0.01', integrateWaitSeconds: '5' };

interface World {
  readonly full: string;
  readonly remote: string;
  readonly checkout: string;
  // Another clone of the same remote, where somebody else works.
  readonly second: string;
}

let fake: FakeForgejo;
let fixture: GitFixture;
let main: World;
let privateWorld: World;
let sibling: World;
const scratch = mkdtempSync(join(tmpdir(), 'forgejo-workflow-'));
const client = new GitClient();

function must<T>(value: T | undefined): T {
  assert.notEqual(value, undefined);
  return value as T;
}

function makeWorld(full: string, isPrivate: boolean): World {
  const [owner = '', name = ''] = full.split('/');
  fake.addRepository(full, { isPrivate });
  const remote = fixture.createRemote(owner, name);
  return { full, remote, checkout: fixture.clone(remote, `project-${owner}`, name), second: fixture.clone(remote, `second-${owner}`, name) };
}

before(async () => {
  fake = await startFakeForgejo();
  fixture = createGitFixture();
  seedLabels(fake, 'o');
  main = makeWorld('o/r', false);
  privateWorld = makeWorld('o/priv', true);
  sibling = makeWorld('o/sibling', true);
  // its issue numbers start above those of o/r, so that no branch of one is named like a branch of the other
  for (let n = 0; n < 300; n++) fake.addIssue(sibling.full, { title: `Filler ${n}, so that the numbers differ`, state: 'closed' });
});
after(async () => {
  await fake.close();
  fixture.dispose();
  rmSync(scratch, { recursive: true, force: true });
});

function ctx(cwd: string, settings: Partial<CommandContext['settings']> = {}, harness: RecordingHarness = createRecordingHarness()): CommandContext {
  return contextFor(fake, { cwd, harness, settings: { forgejoUrl: fake.url, tokenCommand: `printf '%s' ${fake.token}`, labelsFile: undefined, ciGate: 'none', ...settings } });
}

function newIssue(world: World, title = 'Work, so that it gets done', options: { labels?: string[]; assignees?: string[] } = {}): number {
  return fake.addIssue(world.full, { title, labels: options.labels ?? ['status/ready'], assignees: options.assignees ?? ['fake-user'] });
}

async function treeOf(world: World, number: number): Promise<string> {
  const found = (await client.listWorktrees(world.checkout)).find((worktree) => new RegExp(`^issue-${number}(-|$)`).test(worktree.branch ?? ''));
  return must(found).path;
}

async function started(world: World, title?: string): Promise<{ number: number; tree: string; branch: string }> {
  const number = newIssue(world, title);
  await startIssue.run([world.full, String(number)], ctx(world.checkout));
  const tree = await treeOf(world, number);
  return { number, tree, branch: must(await client.currentBranch(tree)) };
}

async function worked(world: World, title?: string): Promise<{ number: number; tree: string; branch: string; head: string }> {
  const issue = await started(world, title);
  const head = fixture.commit(issue.tree, `work-${issue.number}.txt`, 'work\n');
  return { ...issue, head };
}

function integrateArguments(world: World, number: number, head: string, ...extra: string[]): string[] {
  return [world.full, String(number), '--reviewed-by', 'alice', '--reviewed-head', head, ...extra];
}

const tipOf = (world: World): string => git(world.remote, 'rev-parse', 'refs/heads/master');
const writesOf = (): number => fake.writes().length;
const commentsOf = (world: World, number: number): string[] => fake.readIssue(world.full, number).comments;
const remoteBranches = (world: World): string => git(world.remote, 'branch', '--list');
// A commit that origin's default branch lacks, made without moving a branch of the clone.
const unlandedCommit = (world: World): string => git(world.second, 'commit-tree', '-p', 'HEAD', '-m', 'work origin has', 'HEAD^{tree}');

describe('start-issue', () => {
  it('cuts the worktree from the fetched default branch, sets status/implementing and writes Started on', async () => {
    const number = newIssue(main, 'Start the work, so that it begins');
    const moved = fixture.commit(main.second, `moved-${number}.txt`, 'moved\n');
    git(main.second, 'push', '-q', 'origin', 'master');
    const harness = createRecordingHarness();
    const result = await startIssue.run([String(number)], ctx(main.checkout, {}, harness));
    const tree = await treeOf(main, number);
    assert.equal(tree, join(fixture.root, 'project-o', '.worktrees', 'r', `issue-${number}-start-the-work-so-that-it-begins`));
    assert.equal(git(tree, 'rev-parse', 'HEAD'), moved, 'cut from the fetched default, which the checkout never pulled');
    assert.equal(git(tree, 'rev-parse', '--abbrev-ref', '@{upstream}'), 'origin/master');
    const issue = fake.readIssue('o/r', number);
    assert.deepEqual(issue.labels, ['status/implementing']);
    assert.equal(issue.comments.length, 1);
    assert.match(issue.comments[0] ?? '', new RegExp(`^Started on issue-${number}-start-the-work-so-that-it-begins:\\n\\nBase: master at ${moved}\\n$`));
    assert.match(result.stdout, /status\/implementing/);
    assert.deepEqual(harness.calls, [`checkTeamModes ${main.checkout}`, `assembleWorktree ${tree}`], 'the team modes first, then the harness in the new worktree');
    assert.match(result.stdout, /init: assembled/);
    assert.equal(result.stderr, '');
  });

  it('refuses while a team mode is missing, and cuts and writes nothing (planted: no team mode)', async () => {
    const number = newIssue(main, 'No team modes, so that nothing starts');
    const harness = createRecordingHarness();
    harness.failing.add('checkTeamModes');
    const [worktrees, before] = [(await client.listWorktrees(main.checkout)).length, writesOf()];
    await assert.rejects(startIssue.run([String(number)], ctx(main.checkout, {}, harness)), (error: unknown) => error instanceof PreconditionError && /planted: checkTeamModes failed\nthe team modes are missing/.test(error.message));
    assert.equal(writesOf(), before);
    assert.equal((await client.listWorktrees(main.checkout)).length, worktrees);
  });

  it('starts the work and names a harness that init could not assemble in the new worktree (planted: init fails)', async () => {
    const number = newIssue(main, 'Init fails, so that it is named');
    const harness = createRecordingHarness();
    harness.failing.add('assembleWorktree');
    const result = await startIssue.run([String(number)], ctx(main.checkout, {}, harness));
    const tree = await treeOf(main, number);
    assert.match(result.stderr, new RegExp(`the harness is NOT complete in the worktree: run 'ai-core init ${tree.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} --no-doctor'`));
    assert.deepEqual(fake.readIssue('o/r', number).labels, ['status/implementing']);
  });

  it('is run again without cutting or writing twice (innocent case)', async () => {
    const { number, tree } = await started(main, 'Start twice, so that it is safe');
    const before = writesOf();
    const harness = createRecordingHarness();
    const again = await startIssue.run([String(number)], ctx(main.checkout, {}, harness));
    assert.match(again.stdout, /stands on .* already/);
    assert.deepEqual(harness.calls, [`checkTeamModes ${main.checkout}`], 'a worktree that stands is not assembled again');
    assert.equal(fake.readIssue('o/r', number).comments.length, 1);
    assert.equal(writesOf(), before, 'the labels already stand and the record is there');
    assert.ok(existsSync(tree));
  });

  it('writes what a failed run left out, when it is run again', async () => {
    const number = newIssue(main, 'Start after a failure, so that it recovers');
    fake.fail({ method: 'POST', path: `/repos/o/r/issues/${number}/comments`, mode: { kind: 'status', status: 500, message: 'planted' } });
    await assert.rejects(startIssue.run([String(number)], ctx(main.checkout)), (error: unknown) => error instanceof PartialCompletionError && /cut the worktree/.test(error.message));
    assert.equal(fake.readIssue('o/r', number).comments.length, 0);
    await startIssue.run([String(number)], ctx(main.checkout));
    assert.equal(fake.readIssue('o/r', number).comments.length, 1);
  });

  const unready: [string, () => number, RegExp][] = [
    ['an issue assigned to nobody', () => newIssue(main, 'Unassigned, so that it is refused', { assignees: [] }), /assigned to nobody/],
    ['an issue assigned to somebody else', () => fake.addIssue('o/r', { title: 'Theirs, so that it is refused', labels: ['status/ready'], assignees: ['second-user'] }), /not to @fake-user/],
    ['an issue in the backlog', () => newIssue(main, 'Backlog, so that it is refused', { labels: ['status/backlog'] }), /in status\/backlog, and work starts from/],
    ['an issue that landed', () => newIssue(main, 'Landed, so that it is refused', { labels: ['status/testing'] }), /in status\/testing/],
    ['an issue with no status', () => newIssue(main, 'Unlabeled, so that it is refused', { labels: [] }), /no status\/ label/],
    ['a closed issue', () => fake.addIssue('o/r', { title: 'Closed, so that it is refused', state: 'closed', labels: ['status/done'], assignees: ['fake-user'] }), /is closed/],
  ];
  for (const [name, make, message] of unready) {
    it(`refuses ${name}, and cuts and writes nothing`, async () => {
      const number = make();
      const worktrees = (await client.listWorktrees(main.checkout)).length;
      const before = writesOf();
      await assert.rejects(startIssue.run([String(number)], ctx(main.checkout)), (error: unknown) => error instanceof PreconditionError && message.test(error.message));
      assert.equal(writesOf(), before);
      assert.equal((await client.listWorktrees(main.checkout)).length, worktrees);
    });
  }

  it('refuses a branch of the issue that is not its worktree, local or on origin', async () => {
    const local = newIssue(main, 'Local branch, so that it clashes');
    git(main.checkout, 'branch', `issue-${local}-someone-else`);
    await assert.rejects(startIssue.run([String(local)], ctx(main.checkout)), /a branch for issue \d+ exists already: issue-\d+-someone-else/);
    const remote = newIssue(main, 'Remote branch, so that it clashes');
    git(main.second, 'push', '-q', 'origin', `${unlandedCommit(main)}:refs/heads/issue-${remote}-pushed`);
    await assert.rejects(startIssue.run([String(remote)], ctx(main.checkout)), /origin\/issue-\d+-pushed/);
    assert.equal(fake.readIssue('o/r', local).comments.length, 0);
  });

  it('cuts the worktree over an origin branch of the issue that has landed, which its push fast-forwards (planted)', async () => {
    const number = newIssue(main, 'Landed part, so that the next part starts');
    git(main.second, 'push', '-q', 'origin', `HEAD:refs/heads/issue-${number}-landed-part-so-that-the-next-part-starts`);
    const result = await startIssue.run([String(number)], ctx(main.checkout));
    assert.match(result.stdout, /cut from origin\/master/);
    assert.equal(git(await treeOf(main, number), 'rev-parse', 'HEAD'), tipOf(main));
  });

  it('opens the worktree on an origin branch of the issue that holds work no worktree has (planted)', async () => {
    const number = newIssue(main, 'Reviewed work, so that it goes on');
    const branch = `issue-${number}-reviewed-work-so-that-it-goes-on`;
    const work = unlandedCommit(main);
    git(main.second, 'push', '-q', 'origin', `${work}:refs/heads/${branch}`);
    const result = await startIssue.run([String(number)], ctx(main.checkout));
    assert.match(result.stdout, new RegExp(`opened on origin/${branch} at ${work}`));
    assert.equal(git(await treeOf(main, number), 'rev-parse', 'HEAD'), work);
    assert.equal(git(main.checkout, 'config', '--get', `branch.${branch}.merge`), 'refs/heads/master');
  });

  it('records on the branch that the issue lives in another repository, and writes there (innocent case)', async () => {
    const number = newIssue(sibling, 'Elsewhere, so that the repository differs');
    await startIssue.run([sibling.full, String(number)], ctx(main.checkout));
    const tree = await treeOf(main, number);
    const branch = must(await client.currentBranch(tree));
    assert.equal(git(main.checkout, 'config', '--get', `branch.${branch}.issueRepository`), sibling.full);
    assert.deepEqual(fake.readIssue(sibling.full, number).labels, ['status/implementing']);
  });
});

describe('integrate-issue', () => {
  it('lands the reviewed commits as they were read, in a merge commit that names the issue and the reviewers, and records the landing', async () => {
    const { number, tree, head } = await worked(main, 'Land the work, so that it ships');
    const before = tipOf(main);
    const harness = createRecordingHarness();
    const result = await integrateIssue.run([...integrateArguments(main, number, head), '--reviewed-by', 'bob'], ctx(tree, {}, harness));
    const merged = tipOf(main);
    assert.notEqual(merged, before);
    assert.deepEqual(git(main.remote, 'rev-list', '--parents', '-n', '1', merged).split(' ').slice(1), [before, head], 'a merge of the old tip and the reviewed head');
    assert.equal(git(main.remote, 'log', '-1', '--format=%s', merged), `Land the work, so that it ships (#${number})`);
    assert.match(git(main.remote, 'log', '-1', '--format=%b', merged), /^Reviewed-by: alice\nReviewed-by: bob\n?$/);
    const issue = fake.readIssue('o/r', number);
    assert.deepEqual(issue.labels, ['status/testing']);
    assert.match(issue.comments[1] ?? '', new RegExp(`^Landed on master:\\n\\nReviewed head: ${head}\\nLanded commit: ${merged}\\nReviewed by: alice, bob\\n$`));
    assert.match(result.stdout, new RegExp(`next: ai-core finish-issue o/r ${number}`));
    assert.deepEqual(readdirSync(join(fixture.root, 'project-o', '.worktrees', 'r')).filter((name) => name.startsWith('integrate-')), [], 'the temporary worktree is gone');
    assert.equal(await client.isClean(tree), true, 'the worktree of the issue was never touched');
    assert.deepEqual(harness.calls, [`refreshCheckout ${main.checkout}`], 'the main checkout is brought up to the landing');
    assert.match(result.stdout, /refreshed: the checkout/);
  });

  it('names a main checkout it could not refresh, and the landing stands (planted: the refresh fails)', async () => {
    const { number, tree, head } = await worked(main, 'Refresh fails, so that it is named');
    const harness = createRecordingHarness();
    harness.failing.add('refreshCheckout');
    const result = await integrateIssue.run(integrateArguments(main, number, head), ctx(tree, {}, harness));
    assert.equal(result.exitCode, 0);
    assert.match(result.stderr, new RegExp(`planted: refreshCheckout failed\nintegration succeeded: [0-9a-f]{7} is on origin/master; the refresh of checkout ${main.checkout.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} did not finish`));
    assert.deepEqual(fake.readIssue('o/r', number).labels, ['status/testing']);
  });

  it('lands every issue it is given and writes where the work landed for an issue of another repository', async () => {
    const { number, tree, head } = await worked(main, 'Land two issues, so that both move');
    const second = newIssue(main, 'Second issue, so that it lands too', { labels: ['status/implementing'] });
    const third = newIssue(sibling, 'Third issue elsewhere, so that its repository differs', { labels: ['status/implementing'] });
    await integrateIssue.run(integrateArguments(main, number, head, '--also', `o/r#${second}`, '--also', `${sibling.full}#${third}`), ctx(tree));
    for (const [world, n] of [[main, number], [main, second], [sibling, third]] as const) {
      assert.deepEqual(fake.readIssue(world.full, n).labels, ['status/testing'], `${world.full}#${n}`);
    }
    assert.match(commentsOf(main, second)[0] ?? '', /^Landed on master:\n/);
    assert.match(commentsOf(sibling, third)[0] ?? '', /^Landed on master of o\/r:\n/);
  });

  it('discovers no issue from the history: a commit that names another issue gains nothing', async () => {
    const { number, tree, head } = await worked(main, 'Land one issue, so that only it moves');
    const bystander = newIssue(main, 'Named in passing, so that it stays', { labels: ['status/implementing'] });
    git(tree, 'commit', '-q', '--allow-empty', '-m', `Touches the other one (#${bystander})`);
    const reviewed = git(tree, 'rev-parse', 'HEAD');
    await integrateIssue.run(integrateArguments(main, number, reviewed), ctx(tree));
    assert.deepEqual(fake.readIssue('o/r', bystander).labels, ['status/implementing']);
    assert.equal(fake.readIssue('o/r', bystander).comments.length, 0);
    assert.notEqual(head, reviewed);
  });

  describe('refuses, with nothing merged, pushed or written', () => {
    const refusal = async (prepare: () => Promise<{ number: number; tree: string; args: string[] }>, message: RegExp, kind: new (...args: never[]) => Error = PreconditionError): Promise<void> => {
      const { tree, args } = await prepare();
      const [remoteBefore, writesBefore] = [tipOf(main), writesOf()];
      await assert.rejects(integrateIssue.run(args, ctx(tree)), (error: unknown) => error instanceof kind && message.test((error as Error).message));
      assert.equal(tipOf(main), remoteBefore, 'origin is as it was');
      assert.equal(writesOf(), writesBefore, 'the tracker is as it was');
    };

    it('a head that changed after the review', async () => {
      await refusal(async () => {
        const { number, tree, head } = await worked(main, 'Changed after review, so that it is refused');
        fixture.commit(tree, 'sneaked.txt', 'x\n');
        return { number, tree, args: integrateArguments(main, number, head) };
      }, /the head of .* is [0-9a-f]{40}, not the reviewed head [0-9a-f]{40}/);
    });

    it('a worktree with changes', async () => {
      await refusal(async () => {
        const { number, tree, head } = await worked(main, 'Dirty, so that it is refused');
        writeFileSync(join(tree, 'dirty.txt'), 'x');
        return { number, tree, args: integrateArguments(main, number, head) };
      }, /the worktree has changes/);
    });

    it('a directory that is not the worktree of the issue', async () => {
      await refusal(async () => {
        const { number, head } = await worked(main, 'Wrong place, so that it is refused');
        return { number, tree: main.checkout, args: integrateArguments(main, number, head) };
      }, /this runs in the worktree of issue \d+/);
    });

    it('an issue assigned to somebody else', async () => {
      await refusal(async () => {
        const { number, tree, head } = await worked(main, 'Not mine, so that it is refused');
        const theirs = fake.addIssue('o/r', { title: 'Theirs, so that it is refused', labels: ['status/implementing'], assignees: ['second-user'] });
        return { number, tree, args: integrateArguments(main, number, head, '--also', `o/r#${theirs}`) };
      }, /not to @fake-user/);
    });

    it('a closed issue', async () => {
      await refusal(async () => {
        const { number, tree, head } = await worked(main, 'Closed meanwhile, so that it is refused');
        const done = fake.addIssue('o/r', { title: 'Closed, so that it is refused', state: 'closed', labels: ['status/done'], assignees: ['fake-user'] });
        return { number, tree, args: integrateArguments(main, number, head, '--also', `o/r#${done}`) };
      }, /is closed/);
    });

    it('a CI_GATE that is neither public nor none', async () => {
      const { number, tree, head } = await worked(main, 'Bad gate, so that it is refused');
      const before = tipOf(main);
      await assert.rejects(integrateIssue.run(integrateArguments(main, number, head), ctx(tree, { ciGate: 'sometimes' })), /CI_GATE is 'sometimes'.*public or none/);
      assert.equal(tipOf(main), before);
    });

    it('a push gate that is red, showing what the gate said', async () => {
      const { number, tree, head } = await worked(main, 'Red gate, so that it is refused');
      fixture.installHook(main.checkout, 'pre-push', 'echo "gate is red: planted" >&2; exit 1');
      try {
        await refusal(async () => ({ number, tree, args: integrateArguments(main, number, head) }), /nothing landed: the push to master was refused.*gate is red: planted/);
      } finally {
        rmSync(join(main.checkout, '.git', 'hooks', 'pre-push'));
      }
      const innocent = await integrateIssue.run(integrateArguments(main, number, head), ctx(tree));
      assert.match(innocent.stdout, /integrated:/, 'the same landing goes through once the gate is green');
    });

    it('a push gate that is red shows every line it printed while it runs and leaves the worktree on its branch (planted: shown only at the end)', async () => {
      const { number, tree, branch, head } = await worked(main, 'Chatty gate, so that every line shows');
      const lines = Array.from({ length: 12 }, (_, n) => `gate line ${n}`);
      const seen = join(scratch, `seen-${number}`);
      // the gate goes on only once the person has read its first lines, and gives up after ten seconds
      const waitUntilSeen = `n=0; until [ -e '${seen}' ]; do n=$((n + 1)); [ $n -lt 200 ] || { echo "nobody saw the gate while it ran" >&2; exit 1; }; sleep 0.05; done`;
      fixture.installHook(main.checkout, 'pre-push', `${lines.map((line) => `echo "${line}" >&2`).join('; ')}; ${waitUntilSeen}; echo "gate is red: planted" >&2; exit 1`);
      const shown: string[] = [];
      const watching = { ...ctx(tree), stderr: (text: string) => { shown.push(text); if (text.includes('gate line 11')) writeFileSync(seen, ''); } };
      try {
        await assert.rejects(integrateIssue.run(integrateArguments(main, number, head), watching), new RegExp(`nothing landed: the push to master was refused.*gate is red: planted.*\\. this worktree is on ${branch}$`));
      } finally {
        rmSync(join(main.checkout, '.git', 'hooks', 'pre-push'));
      }
      const said = shown.join('');
      assert.ok(lines.every((line) => said.includes(`${line}\n`)), said);
      assert.doesNotMatch(said, /nobody saw the gate/);
      assert.match(said, new RegExp(`^landing: this worktree goes onto origin/master .* git switch ${branch} puts it back$`, 'm'));
      assert.equal(await client.currentBranch(tree), branch, 'the worktree is back on its branch');
      assert.equal(git(tree, 'rev-parse', 'HEAD'), head);
      assert.equal(await client.isClean(tree), true);
    });

    it('a gate that leaves a change behind, which keeps the worktree off its branch and says so, never that it is back (planted: the claim)', async () => {
      const { number, tree, branch, head } = await worked(main, 'Gate leaves a change, so that the branch cannot come back');
      const drift = `drift-${number}.txt`;
      fixture.commit(main.second, drift, 'on master\n');
      git(main.second, 'pull', '-q', '--rebase', 'origin', 'master');
      git(main.second, 'push', '-q', 'origin', 'master');
      fixture.installHook(main.checkout, 'pre-push', `echo changed >> ${drift}; echo "gate is red: planted" >&2; exit 1`);
      try {
        await assert.rejects(integrateIssue.run(integrateArguments(main, number, head), ctx(tree)), (error: unknown) => {
          const message = error instanceof PreconditionError ? error.message : '';
          return message.includes(`${branch} could not be checked out again, run git switch ${branch} before finish-issue`) && !message.includes(`${branch} is checked out again`) && !message.includes('this worktree is on');
        });
      } finally {
        rmSync(join(main.checkout, '.git', 'hooks', 'pre-push'));
      }
      assert.equal(await client.currentBranch(tree), undefined, 'the worktree stays detached, as the message says');
      git(tree, 'checkout', '-q', '--', drift);
      git(tree, 'switch', '-q', branch);
      assert.equal(git(tree, 'rev-parse', 'HEAD'), head);
    });

    it('a worktree with changes, naming them, before anything moves', async () => {
      const { number, tree, branch, head } = await worked(main, 'Dirty and named, so that it is refused');
      writeFileSync(join(tree, 'staged.txt'), 'x');
      git(tree, 'add', 'staged.txt');
      writeFileSync(join(tree, 'loose.txt'), 'x');
      const remoteBefore = tipOf(main);
      await assert.rejects(integrateIssue.run(integrateArguments(main, number, head), ctx(tree)), (error: unknown) => error instanceof PreconditionError && /A  staged\.txt\n\?\? loose\.txt/.test(error.message));
      assert.equal(tipOf(main), remoteBefore);
      assert.equal(await client.currentBranch(tree), branch);
    });

    it('a worktree with an untracked folder of many files, naming twenty of them and how many there are (planted: 25 files)', async () => {
      const { number, tree, head } = await worked(main, 'Many loose files, so that the list stays short');
      mkdirSync(join(tree, 'loose'));
      for (let n = 0; n < 25; n++) writeFileSync(join(tree, 'loose', `file-${String(n).padStart(2, '0')}.txt`), 'x');
      await assert.rejects(integrateIssue.run(integrateArguments(main, number, head), ctx(tree)), (error: unknown) => {
        const listed = error instanceof PreconditionError ? error.message.split('\n').slice(1) : [];
        return listed.length === 21 && listed[0] === '?? loose/file-00.txt' && listed[19] === '?? loose/file-19.txt' && listed[20] === 'and 5 more, 25 in all';
      });
    });

    it('an ignored file of the worktree that origin/master tracks, which stays as it was (planted: the switch overwrites it)', async () => {
      const { number, tree, branch } = await started(main, 'Ignored and mine, so that it is refused');
      const kept = `kept-${number}.txt`;
      const head = fixture.commit(tree, '.gitignore', `${kept}\n`);
      writeFileSync(join(tree, kept), 'my own\n');
      fixture.commit(main.second, kept, 'tracked on master\n');
      git(main.second, 'pull', '-q', '--rebase', 'origin', 'master');
      git(main.second, 'push', '-q', 'origin', 'master');
      await refusal(async () => ({ number, tree, args: integrateArguments(main, number, head) }), new RegExp(`nothing landed: this worktree could not be put on origin/master for the merge .*${kept}`));
      assert.equal(readFileSync(join(tree, kept), 'utf8'), 'my own\n');
      assert.equal(await client.currentBranch(tree), branch);
      assert.equal(git(tree, 'rev-parse', 'HEAD'), head);
    });

    it('a branch that does not merge cleanly, leaving the worktree clean on its branch', async () => {
      let conflicted = { tree: '', branch: '', head: '' };
      await refusal(async () => {
        const { number, tree, branch } = await worked(main, 'Conflict, so that it is refused');
        const head = fixture.commit(tree, 'conflict.txt', 'branch\n');
        conflicted = { tree, branch, head };
        fixture.commit(main.second, 'conflict.txt', 'main\n');
        git(main.second, 'pull', '-q', '--rebase', 'origin', 'master');
        git(main.second, 'push', '-q', 'origin', 'master');
        return { number, tree, args: integrateArguments(main, number, head) };
      }, /does not merge cleanly into origin\/master.*\. this worktree is on issue-\d+-conflict-so-that-it-is-refused$/);
      assert.equal(await client.isClean(main.checkout), true);
      assert.equal(await client.currentBranch(conflicted.tree), conflicted.branch);
      assert.equal(git(conflicted.tree, 'rev-parse', 'HEAD'), conflicted.head);
      assert.equal(await client.isClean(conflicted.tree), true);
    });

    it('a missing reviewer, a missing head and a head that is no commit', async () => {
      const { number, tree, head } = await worked(main, 'Unreviewed, so that it is refused');
      await assert.rejects(integrateIssue.run([main.full, String(number), '--reviewed-head', head], ctx(tree)), UsageError);
      await assert.rejects(integrateIssue.run([main.full, String(number), '--reviewed-by', 'alice'], ctx(tree)), UsageError);
      await assert.rejects(integrateIssue.run([main.full, String(number), '--reviewed-by', 'alice', '--reviewed-head', 'zzzzzzz'], ctx(tree)), UsageError);
      await assert.rejects(integrateIssue.run([main.full, String(number), '--reviewed-by', 'alice', '--reviewed-head', 'abcdef1'], ctx(tree)), /is no commit of this clone/);
    });
  });

  it('writes the lines of the push gate to the stderr of cli.mts, the token redacted (planted: the gate prints the token)', async () => {
    const { number, tree, head } = await worked(main, 'Through the command line, so that the person reads the gate');
    fixture.installHook(main.checkout, 'pre-push', `echo "gate line with ${FAKE_TOKEN}" >&2; exit 1`);
    const environment = { ...process.env, FORGEJO_URL: fake.url, TRACKER: 'forgejo', FORGEJO_TOKEN_COMMAND: `printf '%s' ${FAKE_TOKEN}`, CI_GATE: 'none' };
    const outcome = await new Promise<{ status: number | null; stderr: string }>((done) => {
      const child = spawn('node', [join(import.meta.dirname, '..', 'cli.mts'), 'integrate-issue', ...integrateArguments(main, number, head)], { cwd: tree, env: environment });
      let stderr = '';
      child.stderr.on('data', (chunk: Buffer) => (stderr += chunk.toString()));
      child.on('close', (status) => done({ status, stderr }));
    }).finally(() => rmSync(join(main.checkout, '.git', 'hooks', 'pre-push')));
    assert.equal(outcome.status, 1, outcome.stderr);
    assert.match(outcome.stderr, /^landing: this worktree goes onto origin\/master/m);
    assert.match(outcome.stderr, /^gate line with \[token\]$/m);
    assert.equal(outcome.stderr.includes(FAKE_TOKEN), false);
  });

  it('lands through a push gate that needs a file only the worktree of the issue has (planted: the gate runs elsewhere)', async () => {
    const { number, tree, branch, head } = await worked(main, 'Gate needs tools, so that it runs in the worktree');
    mkdirSync(join(tree, 'node_modules'));
    writeFileSync(join(tree, 'node_modules', '.ok'), '');
    appendFileSync(join(main.checkout, '.git', 'info', 'exclude'), 'node_modules/\n');
    fixture.installHook(main.checkout, 'pre-push', 'test -f node_modules/.ok || { echo "node_modules is missing" >&2; exit 1; }');
    try {
      const result = await integrateIssue.run(integrateArguments(main, number, head), ctx(tree));
      assert.match(result.stdout, /integrated:/);
    } finally {
      rmSync(join(main.checkout, '.git', 'hooks', 'pre-push'));
    }
    assert.equal(await client.currentBranch(tree), branch, 'the worktree is on its branch again');
    assert.equal(git(tree, 'rev-parse', 'HEAD'), head);
  });

  describe('under CI_GATE=public', () => {
    const publicSettings = { ciGate: undefined, ...FAST };

    it('lands exactly the commit whose checks were green, removes the branch it pushed for them, and reads the checks of a public repository only', async () => {
      const { number, tree, head } = await worked(main, 'Land on green, so that checks decide');
      fake.setChecks(main.full, ['pending', 'success']);
      const before = fake.requests.length;
      const result = await integrateIssue.run(integrateArguments(main, number, head), ctx(tree, publicSettings));
      const merged = tipOf(main);
      const asked = fake.requests.slice(before).filter((request) => request.path.includes('/commits/')).map((request) => request.path);
      assert.ok(asked.length >= 2 && asked.every((path) => path === `/repos/o/r/commits/${merged}/status`), `the checks of the commit that landed: ${asked.join()}`);
      assert.doesNotMatch(remoteBranches(main), /ci\/integrate/);
      assert.match(result.stdout, /checks: green for/);
    });

    it('installs the tools in the temporary worktree before the push, so a gate that needs them lets the landing through (planted: no install)', async () => {
      const { number, tree } = await worked(main, 'Install first, so that the gate finds its tools');
      mkdirSync(join(tree, 'scripts'), { recursive: true });
      writeFileSync(join(tree, 'scripts', 'install.sh'), 'mkdir -p node_modules && echo "installing the tools" && touch node_modules/.ok\n');
      git(tree, 'add', 'scripts/install.sh');
      git(tree, 'commit', '-q', '-m', 'Add the install');
      const installed = git(tree, 'rev-parse', 'HEAD');
      appendFileSync(join(main.checkout, '.git', 'info', 'exclude'), 'node_modules/\n');
      // the delete of the branch for the checks runs from the worktree of the issue, which holds no tools
      fixture.installHook(main.checkout, 'pre-push', 'read -r ref sha rest; case "$sha" in 0*) exit 0;; esac\ntest -f node_modules/.ok || { echo "node_modules is missing" >&2; exit 1; }');
      fake.setChecks(main.full, ['success']);
      const shown: string[] = [];
      const harness = { ...createRecordingHarness(), installTools: bashHarness.installTools };
      try {
        const result = await integrateIssue.run(integrateArguments(main, number, installed), { ...ctx(tree, publicSettings, harness), stderr: (text) => shown.push(text) });
        assert.match(result.stdout, /checks: green for/);
        assert.match(shown.join(''), /^installing the tools$/m);
      } finally {
        rmSync(join(main.checkout, '.git', 'hooks', 'pre-push'));
      }
      git(main.remote, 'merge-base', '--is-ancestor', installed, tipOf(main));
      assert.doesNotMatch(remoteBranches(main), /ci\/integrate/);
      assert.ok(!existsSync(join(tree, 'node_modules')), 'the install never ran in the worktree of the issue');
      assert.deepEqual(readdirSync(join(fixture.root, 'project-o', '.worktrees', 'r')).filter((name) => name.startsWith('integrate-')), [], 'the temporary worktree is gone, with what the install wrote');
    });

    it('lands nothing when the install fails, shows its lines and leaves no half-installed tree (planted: the install writes, then exits 1)', async () => {
      const { number, tree } = await worked(main, 'Install fails, so that it is refused');
      mkdirSync(join(tree, 'scripts'), { recursive: true });
      writeFileSync(join(tree, 'scripts', 'install.sh'), 'mkdir -p node_modules && touch node_modules/.half\necho "the install broke" >&2\nexit 1\n');
      git(tree, 'add', 'scripts/install.sh');
      git(tree, 'commit', '-q', '-m', 'Add a failing install');
      const installed = git(tree, 'rev-parse', 'HEAD');
      fake.setChecks(main.full, ['success']);
      const [before, writes] = [tipOf(main), writesOf()];
      const shown: string[] = [];
      const harness = { ...createRecordingHarness(), installTools: bashHarness.installTools };
      await assert.rejects(
        integrateIssue.run(integrateArguments(main, number, installed), { ...ctx(tree, publicSettings, harness), stderr: (text) => shown.push(text) }),
        (error: unknown) => error instanceof PreconditionError && /nothing landed: scripts\/install.sh failed.*the install broke/.test(error.message),
      );
      assert.match(shown.join(''), /^the install broke$/m);
      assert.equal(tipOf(main), before);
      assert.equal(writesOf(), writes);
      assert.doesNotMatch(remoteBranches(main), /ci\/integrate/);
      assert.deepEqual(readdirSync(join(fixture.root, 'project-o', '.worktrees', 'r')).filter((name) => name.startsWith('integrate-')), [], 'the temporary worktree is gone, with what the install wrote');
      assert.doesNotMatch(git(main.checkout, 'worktree', 'list', '--porcelain'), /integrate-/, 'no temporary worktree stays registered');
    });

    it('lands nothing on red checks, and removes the branch it pushed for them (planted: red)', async () => {
      const { number, tree, head } = await worked(main, 'Red checks, so that it is refused');
      fake.setChecks(main.full, ['failure']);
      const [before, writes] = [tipOf(main), writesOf()];
      await assert.rejects(integrateIssue.run(integrateArguments(main, number, head), ctx(tree, publicSettings)), /the checks for [0-9a-f]{40} on ci\/integrate-.* are red/);
      assert.equal(tipOf(main), before);
      assert.equal(writesOf(), writes);
      assert.doesNotMatch(remoteBranches(main), /ci\/integrate/);
    });

    it('lands nothing on checks that do not finish (planted: pending for good)', async () => {
      const { number, tree, head } = await worked(main, 'Unfinished checks, so that it is refused');
      fake.setChecks(main.full, ['pending']);
      const before = tipOf(main);
      await assert.rejects(integrateIssue.run(integrateArguments(main, number, head), ctx(tree, { ciGate: undefined, integratePollSeconds: '0.01', integrateWaitSeconds: '0.05' })), /did not finish in 0.05 seconds/);
      assert.equal(tipOf(main), before);
      assert.doesNotMatch(remoteBranches(main), /ci\/integrate/);
    });

    it('lands nothing when the default branch moved while the checks ran', async () => {
      const { number, tree, head } = await worked(main, 'Moved meanwhile, so that it is refused');
      fake.setChecks(main.full, ['success']);
      const marker = join(scratch, `moved-${number}`);
      const mover = `unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; [ ! -e '${marker}' ] || exit 0; touch '${marker}'; cd '${main.second}' && git pull -q --rebase origin master && echo moved > moved-meanwhile.txt && git add moved-meanwhile.txt && git commit -qm moved && git push -q origin HEAD:master`;
      fixture.installHook(main.checkout, 'pre-push', mover);
      try {
        const writes = writesOf();
        await assert.rejects(integrateIssue.run(integrateArguments(main, number, head), ctx(tree, publicSettings)), /origin\/master moved from [0-9a-f]{40} to [0-9a-f]{40}/);
        assert.equal(git(main.remote, 'log', '-1', '--format=%s', 'refs/heads/master'), 'moved');
        assert.equal(writesOf(), writes);
        assert.doesNotMatch(remoteBranches(main), /ci\/integrate/);
      } finally {
        rmSync(join(main.checkout, '.git', 'hooks', 'pre-push'));
      }
    });

    it('rests on the push gate for a private repository and reads no checks (innocent case)', async () => {
      const { number, tree, head } = await worked(privateWorld, 'Private, so that the gate is the check');
      fake.setChecks(privateWorld.full, ['failure']);
      const before = fake.requests.length;
      const result = await integrateIssue.run(integrateArguments(privateWorld, number, head), ctx(tree, publicSettings));
      assert.equal(fake.requests.slice(before).some((request) => request.path.includes('/commits/')), false);
      assert.match(result.stdout, /is private, its push gate is its check/);
      assert.deepEqual(fake.readIssue(privateWorld.full, number).labels, ['status/testing']);
    });
  });

  describe('after a failure of the tracker', () => {
    it('exits partly done with the landing named, and a second run merges and pushes nothing and writes only what is missing', async () => {
      const { number, tree, head } = await worked(main, 'Fail after landing, so that it recovers');
      fake.fail({ method: 'POST', path: `/repos/o/r/issues/${number}/comments`, mode: { kind: 'status', status: 500, message: 'planted' } });
      await assert.rejects(integrateIssue.run(integrateArguments(main, number, head), ctx(tree)), (error: unknown) => error instanceof PartialCompletionError && /landed [0-9a-f]{40} on origin\/master/.test(error.message) && /run the same command again/.test(error.message));
      const landed = tipOf(main);
      assert.equal(git(main.remote, 'merge-base', '--is-ancestor', head, landed) === '', true);
      assert.equal(commentsOf(main, number).filter((text) => text.startsWith('Landed on')).length, 0);

      const again = await integrateIssue.run(integrateArguments(main, number, head), ctx(tree));
      assert.equal(tipOf(main), landed, 'no second merge and no second push');
      assert.match(again.stdout, /already landed/);
      assert.equal(commentsOf(main, number).filter((text) => text.startsWith('Landed on')).length, 1);
      assert.match(commentsOf(main, number).find((text) => text.startsWith('Landed on')) ?? '', new RegExp(`Landed commit: ${landed}`));
      assert.deepEqual(fake.readIssue('o/r', number).labels, ['status/testing']);

      const before = writesOf();
      await integrateIssue.run(integrateArguments(main, number, head), ctx(tree));
      assert.equal(writesOf(), before, 'a third run writes nothing');
    });

    it('writes only the records a timeline that could not be read left out, also for an issue whose worktree was removed meanwhile', async () => {
      const number = newIssue(main, 'Timeline fails twice, so that two records are missing');
      const timeline = { method: 'GET', path: `/repos/o/r/issues/${number}/timeline`, mode: { kind: 'status', status: 500, message: 'planted' } } as const;
      fake.fail(timeline);
      await assert.rejects(startIssue.run([String(number)], ctx(main.checkout)), (error: unknown) => error instanceof PartialCompletionError && /cut the worktree/.test(error.message));
      assert.deepEqual(fake.readIssue('o/r', number).labels, ['status/implementing']);
      assert.equal(commentsOf(main, number).length, 0);
      const tree = await treeOf(main, number);
      const branch = must(await client.currentBranch(tree));
      const head = fixture.commit(tree, `work-${number}.txt`, 'work\n');
      fake.fail(timeline);
      await assert.rejects(integrateIssue.run(integrateArguments(main, number, head), ctx(tree)), (error: unknown) => error instanceof PartialCompletionError && /landed [0-9a-f]{40} on origin\/master/.test(error.message));
      const landed = tipOf(main);
      assert.equal(commentsOf(main, number).length, 0);

      // the state finish-issue left before it asked for the landing record: the work landed, the worktree and the branch are gone
      await client.removeWorktree(main.checkout, tree);
      git(main.checkout, 'branch', '-D', branch);

      await startIssue.run([String(number)], ctx(main.checkout));
      assert.deepEqual(commentsOf(main, number).map((text) => text.split(':')[0]), [`Started on ${branch}`], 'the worktree is cut again from the default branch: only the start record is written');
      assert.deepEqual(fake.readIssue('o/r', number).labels, ['status/implementing']);
      await integrateIssue.run(integrateArguments(main, number, head), ctx(main.checkout));
      assert.equal(tipOf(main), landed, 'nothing is merged or pushed again');
      assert.deepEqual(commentsOf(main, number).map((text) => text.split(':')[0]), [`Started on ${branch}`, 'Landed on master']);
      assert.match(commentsOf(main, number)[1] ?? '', new RegExp(`Reviewed head: ${head}\\nLanded commit: ${landed}`));
      assert.deepEqual(fake.readIssue('o/r', number).labels, ['status/testing']);
      const before = writesOf();
      await assert.rejects(startIssue.run([String(number)], ctx(main.checkout)), /in status\/testing, and work starts from/, 'start-issue does not start work that landed');
      assert.equal(writesOf(), before);
    });

    it('writes the start record of an issue whose worktree and branch are gone by cutting a worktree again, from the default branch as it stands', async () => {
      const number = newIssue(main, 'Worktree gone before the start record, so that it is cut again');
      fake.fail({ method: 'GET', path: `/repos/o/r/issues/${number}/timeline`, mode: { kind: 'status', status: 500, message: 'planted' } });
      await assert.rejects(startIssue.run([String(number)], ctx(main.checkout)), PartialCompletionError);
      const tree = await treeOf(main, number);
      const branch = must(await client.currentBranch(tree));
      await client.removeWorktree(main.checkout, tree);
      git(main.checkout, 'branch', '-D', branch);
      await startIssue.run([String(number)], ctx(main.checkout));
      assert.equal(await treeOf(main, number), tree);
      assert.match(commentsOf(main, number)[0] ?? '', new RegExp(`^Started on ${branch}:\\n\\nBase: master at ${tipOf(main)}\\n$`));
      assert.equal(commentsOf(main, number).length, 1);
    });

    it('does not write the record twice when the answer of the comment was lost (planted: a lost answer)', async () => {
      const { number, tree, head } = await worked(main, 'Lost answer, so that nothing repeats');
      fake.fail({ method: 'POST', path: `/repos/o/r/issues/${number}/comments`, mode: { kind: 'drop-after' } });
      await assert.rejects(integrateIssue.run(integrateArguments(main, number, head), ctx(tree)), PartialCompletionError);
      await integrateIssue.run(integrateArguments(main, number, head), ctx(tree));
      assert.equal(commentsOf(main, number).filter((text) => text.startsWith('Landed on')).length, 1);
      assert.deepEqual(fake.readIssue('o/r', number).labels, ['status/testing']);
    });
  });

  describe('the rerun once finish-issue removed the worktree', () => {
    // The work landed, the tracker refused the records, and finish-issue then took the worktree and its branch away.
    async function landedWithoutRecords(issueWorld: World, title: string): Promise<{ number: number; tree: string; branch: string; head: string; landed: string; args: string[] }> {
      const number = newIssue(issueWorld, title);
      await startIssue.run([issueWorld.full, String(number)], ctx(main.checkout));
      const tree = await treeOf(main, number);
      const branch = must(await client.currentBranch(tree));
      const head = fixture.commit(tree, `work-${number}.txt`, 'work\n');
      const args = [issueWorld.full, String(number), '--reviewed-by', 'alice', '--reviewed-head', head];
      fake.fail({ method: 'POST', path: `/repos/${issueWorld.full}/issues/${number}/comments`, mode: { kind: 'status', status: 500, message: 'planted' } });
      await assert.rejects(integrateIssue.run(args, ctx(tree)), PartialCompletionError);
      return { number, tree, branch, head, landed: tipOf(main), args };
    }
    const removeTree = async (tree: string, branch: string): Promise<void> => {
      await client.removeWorktree(main.checkout, tree);
      git(main.checkout, 'branch', '-D', branch);
    };

    it('writes the missing records from the main checkout, merging and pushing nothing', async () => {
      const issue = await landedWithoutRecords(main, 'Gone worktree of the origin, so that the rerun comes from the main checkout');
      await removeTree(issue.tree, issue.branch);
      const result = await integrateIssue.run(issue.args, ctx(main.checkout));
      assert.equal(tipOf(main), issue.landed, 'nothing is merged or pushed');
      assert.match(result.stdout, /already landed/);
      assert.match(commentsOf(main, issue.number)[1] ?? '', new RegExp(`^Landed on master:\\n\\nReviewed head: ${issue.head}\\nLanded commit: ${issue.landed}\\n`));
      assert.deepEqual(fake.readIssue('o/r', issue.number).labels, ['status/testing']);
      const before = writesOf();
      await integrateIssue.run(issue.args, ctx(main.checkout));
      assert.equal(writesOf(), before, 'a second rerun writes nothing');
    });

    it('writes them for an issue of another repository that OWNER/REPO names, the branch with its recorded repository being gone', async () => {
      const issue = await landedWithoutRecords(sibling, 'Gone worktree elsewhere, so that the repository is named');
      await removeTree(issue.tree, issue.branch);
      assert.equal(await client.getConfig(main.checkout, `branch.${issue.branch}.issueRepository`), undefined, 'the recorded repository went with the branch');
      await integrateIssue.run(issue.args, ctx(main.checkout));
      assert.equal(tipOf(main), issue.landed);
      assert.match(commentsOf(sibling, issue.number).find((text) => text.startsWith('Landed on')) ?? '', /^Landed on master of o\/r:\n/);
      assert.deepEqual(fake.readIssue(sibling.full, issue.number).labels, ['status/testing']);
    });

    it('writes them from a worktree that start-issue cut again on the branch of the issue, whose head is not the reviewed head', async () => {
      const issue = await landedWithoutRecords(main, 'Worktree cut again, so that its head differs');
      await removeTree(issue.tree, issue.branch);
      await startIssue.run([String(issue.number)], ctx(main.checkout));
      const again = await treeOf(main, issue.number);
      assert.notEqual(git(again, 'rev-parse', 'HEAD'), issue.head);
      await integrateIssue.run(issue.args, ctx(again));
      assert.equal(tipOf(main), issue.landed);
      assert.ok(commentsOf(main, issue.number).some((text) => text.startsWith('Landed on master:')));
      assert.deepEqual(fake.readIssue('o/r', issue.number).labels, ['status/testing']);
    });

    it('refuses and writes nothing for a landed commit that names another issue (planted: the landing names #1)', async () => {
      const number = newIssue(main, 'Landed under another name, so that it is not recorded');
      await startIssue.run([String(number)], ctx(main.checkout));
      const tree = await treeOf(main, number);
      const branch = must(await client.currentBranch(tree));
      const head = fixture.commit(tree, `work-${number}.txt`, 'work\n');
      git(tree, 'push', '-q', 'origin', `HEAD:refs/heads/${branch}`);
      git(main.second, 'fetch', '-q', 'origin');
      git(main.second, 'merge', '--no-ff', '-q', '-m', 'Somebody else\'s landing (#1)', `origin/${branch}`);
      git(main.second, 'push', '-q', 'origin', 'HEAD:refs/heads/master');
      await removeTree(tree, branch);
      const [tipBefore, writesBefore] = [tipOf(main), writesOf()];
      await assert.rejects(integrateIssue.run(integrateArguments(main, number, head), ctx(main.checkout)), (error: unknown) => error instanceof PreconditionError && new RegExp(`nothing is written: ${head} is on origin/master, but in the commit [0-9a-f]{7}, whose subject does not end with \\(#${number}\\)`).test(error.message));
      assert.equal(tipOf(main), tipBefore);
      assert.equal(writesOf(), writesBefore);
      assert.deepEqual(fake.readIssue('o/r', number).labels, ['status/implementing']);
    });

    it('refuses and writes nothing for a head pushed directly, whose landing commit is the head itself, but takes it in the worktree on that head (innocent case)', async () => {
      const number = newIssue(main, 'Pushed directly, so that no commit names it');
      await startIssue.run([String(number)], ctx(main.checkout));
      const tree = await treeOf(main, number);
      const head = fixture.commit(tree, `work-${number}.txt`, 'work\n');
      git(tree, 'push', '-q', 'origin', 'HEAD:refs/heads/master');
      const writesBefore = writesOf();
      await assert.rejects(integrateIssue.run(integrateArguments(main, number, head), ctx(main.checkout)), /whose subject does not end with/);
      assert.equal(writesOf(), writesBefore);
      await integrateIssue.run(integrateArguments(main, number, head), ctx(tree));
      assert.ok(commentsOf(main, number).some((text) => text.startsWith('Landed on master:')), 'the worktree on the head ties it to the issue');
      assert.deepEqual(fake.readIssue('o/r', number).labels, ['status/testing']);
    });

    it('still refuses a head that is not on origin when the worktree is gone (planted: an unlanded head)', async () => {
      const issue = await worked(main, 'Unlanded and gone, so that the rerun refuses');
      await removeTree(issue.tree, issue.branch);
      const [tipBefore, writesBefore] = [tipOf(main), writesOf()];
      await assert.rejects(integrateIssue.run(integrateArguments(main, issue.number, issue.head), ctx(main.checkout)), (error: unknown) => error instanceof PreconditionError && /this runs in the worktree of issue \d+, on its branch issue-\d+-\*; here master is checked out/.test(error.message));
      assert.equal(tipOf(main), tipBefore);
      assert.equal(writesOf(), writesBefore);
    });
  });
});

describe('finish-issue', () => {
  it('removes the worktree and the branch of the issue that landed, writes nothing, and leaves every other worktree', async () => {
    const landed = await worked(main, 'Finish after landing, so that it is removed');
    const other = await worked(main, 'Another issue in work, so that it stays');
    await integrateIssue.run(integrateArguments(main, landed.number, landed.head), ctx(landed.tree));
    const writes = writesOf();
    const result = await finishIssue.run([String(landed.number)], ctx(main.checkout));
    assert.equal(writesOf(), writes, 'the card moved at the landing; this writes nothing');
    assert.ok(!existsSync(landed.tree));
    assert.ok(!(await client.listBranchNames(main.checkout)).includes(landed.branch));
    assert.ok(existsSync(other.tree), 'the worktree of another issue stays');
    assert.match(result.stdout, /removed the worktree/);
  });

  it('removes the branch of an issue that landed with a commit its upstream lacks (planted: refused as not fully merged)', async () => {
    const landed = await worked(main, 'Pushed with an upstream before its last commit, so that it is removed');
    git(landed.tree, 'push', '--quiet', '--set-upstream', 'origin', `HEAD:refs/heads/${landed.branch}`);
    const head = fixture.commit(landed.tree, `last-${landed.number}.txt`, 'last\n');
    await integrateIssue.run(integrateArguments(main, landed.number, head), ctx(landed.tree));
    const result = await finishIssue.run([String(landed.number)], ctx(main.checkout));
    assert.match(result.stdout, /removed the worktree/);
    assert.ok(!(await client.listBranchNames(main.checkout)).includes(landed.branch));
  });

  it('keeps the worktree of work that landed without its record, names integrate-issue, and removes it once the record is written (planted: the record is missing)', async () => {
    const { number, tree, branch, head } = await worked(main, 'Landed without a record, so that it stays');
    fake.fail({ method: 'POST', path: `/repos/o/r/issues/${number}/comments`, mode: { kind: 'status', status: 500, message: 'planted' }, times: 1 });
    await assert.rejects(integrateIssue.run(integrateArguments(main, number, head), ctx(tree)), PartialCompletionError);
    const before = writesOf();
    await assert.rejects(finishIssue.run([String(number)], ctx(main.checkout)), (error: unknown) => error instanceof PreconditionError && new RegExp(`carries no "Landed on" record of ${head}.*ai-core integrate-issue o/r ${number} --reviewed-by NAME --reviewed-head ${head}`).test(error.message));
    assert.equal(writesOf(), before);
    assert.ok(existsSync(tree), 'the worktree stays');
    assert.ok((await client.listBranchNames(main.checkout)).includes(branch), 'the branch stays');

    await integrateIssue.run(integrateArguments(main, number, head), ctx(tree));
    const result = await finishIssue.run([String(number)], ctx(main.checkout));
    assert.match(result.stdout, /removed the worktree/);
    assert.ok(!existsSync(tree));
    assert.ok(!(await client.listBranchNames(main.checkout)).includes(branch));
  });

  it('does not take the record of an account without write permission, nor one that names another head, for the landing (planted: two forged records)', async () => {
    const { number, tree, branch, head } = await worked(main, 'Forged record, so that it stays');
    fake.fail({ method: 'POST', path: `/repos/o/r/issues/${number}/comments`, mode: { kind: 'status', status: 500, message: 'planted' }, times: 1 });
    await assert.rejects(integrateIssue.run(integrateArguments(main, number, head), ctx(tree)), PartialCompletionError);
    const landed = tipOf(main);
    fake.setPermission(main.full, 'stranger', 'read');
    const record = (reviewedHead: string): string => composeLandedRecord({ branch: 'master', repository: { owner: 'o', repo: 'r' }, reviewedHead, landedCommit: landed, reviewers: ['alice'] }, { owner: 'o', repo: 'r' });
    fake.addComment(main.full, number, 'stranger', record(head));
    fake.addComment(main.full, number, 'fake-user', record('d'.repeat(40)));
    await assert.rejects(finishIssue.run([String(number)], ctx(main.checkout)), /carries no "Landed on" record of/);
    assert.ok(existsSync(tree));
    fake.addComment(main.full, number, 'fake-user', record(head));
    await finishIssue.run([String(number)], ctx(main.checkout));
    assert.ok(!existsSync(tree));
    assert.ok(!(await client.listBranchNames(main.checkout)).includes(branch));
  });

  it('removes the worktree it is run from, as a session in it would', async () => {
    const landed = await worked(main, 'Finish from inside, so that it works');
    await integrateIssue.run(integrateArguments(main, landed.number, landed.head), ctx(landed.tree));
    await finishIssue.run([String(landed.number)], ctx(landed.tree));
    assert.ok(!existsSync(landed.tree));
  });

  it('keeps a worktree whose work did not land, and one with changes (planted: unlanded and dirty)', async () => {
    const unlanded = await worked(main, 'Not landed, so that it stays');
    await assert.rejects(finishIssue.run([String(unlanded.number)], ctx(main.checkout)), /is not on origin\/master: the work did not land/);
    assert.ok(existsSync(unlanded.tree));
    const landed = await worked(main, 'Dirty after landing, so that it stays');
    await integrateIssue.run(integrateArguments(main, landed.number, landed.head), ctx(landed.tree));
    writeFileSync(join(landed.tree, 'somebody.txt'), 'work in progress');
    await assert.rejects(finishIssue.run([String(landed.number)], ctx(main.checkout)), /has changes, so it stays/);
    assert.ok(existsSync(join(landed.tree, 'somebody.txt')));
  });

  it('deletes the landed branch on origin that its Started record names, and leaves a branch of that number nobody started (planted: it stayed on origin)', async () => {
    const landed = await worked(main, 'Pushed and landed, so that origin keeps no branch of it');
    git(landed.tree, 'push', '--quiet', 'origin', `HEAD:refs/heads/${landed.branch}`);
    git(landed.tree, 'push', '--quiet', 'origin', `${tipOf(main)}:refs/heads/issue-${landed.number}-nobody-started-this`);
    await integrateIssue.run(integrateArguments(main, landed.number, landed.head), ctx(landed.tree));
    const result = await finishIssue.run([String(landed.number)], ctx(main.checkout));
    assert.match(result.stdout, new RegExp(`the branch ${landed.branch} on origin deleted: origin/master holds its tip ${landed.head.slice(0, 7)}`));
    assert.ok(!remoteBranches(main).includes(landed.branch));
    assert.ok(remoteBranches(main).includes(`issue-${landed.number}-nobody-started-this`), 'a branch no Started record names stays');
  });

  it('deletes a landed branch on origin where no worktree stands, and keeps one with work origin lacks (planted: refused before; innocent case: unlanded)', async () => {
    const landed = await worked(main, 'Finished by hand earlier, so that its branch on origin is left');
    git(landed.tree, 'push', '--quiet', 'origin', `HEAD:refs/heads/${landed.branch}`);
    await integrateIssue.run(integrateArguments(main, landed.number, landed.head), ctx(landed.tree));
    git(main.checkout, 'worktree', 'remove', landed.tree);
    git(main.checkout, 'branch', '-D', landed.branch);
    const result = await finishIssue.run([String(landed.number)], ctx(main.checkout));
    assert.match(result.stdout, new RegExp(`no worktree of o/r#${landed.number} stands in this clone\\n.*the branch ${landed.branch} on origin deleted`));
    assert.ok(!remoteBranches(main).includes(landed.branch));

    const unlanded = await worked(main, 'Pushed and not landed, so that its branch on origin stays');
    git(unlanded.tree, 'push', '--quiet', 'origin', `HEAD:refs/heads/${unlanded.branch}`);
    git(main.checkout, 'worktree', 'remove', unlanded.tree);
    git(main.checkout, 'branch', '-D', unlanded.branch);
    await assert.rejects(finishIssue.run([String(unlanded.number)], ctx(main.checkout)), new RegExp(`stands in this clone, so nothing is removed; the branch ${unlanded.branch} on origin stays: it holds commits that origin/master lacks`));
    assert.ok(remoteBranches(main).includes(unlanded.branch));
  });

  it('refuses an issue with no worktree here', async () => {
    await assert.rejects(finishIssue.run(['99999'], ctx(main.checkout)), /no worktree of o\/r#99999 stands in this clone/);
  });

  it('names a worktree that stands detached, as a killed landing leaves it, and removes nothing (planted: detached; innocent case: no worktree)', async () => {
    const landed = await worked(main, 'Detached after landing, so that it is named');
    await integrateIssue.run(integrateArguments(main, landed.number, landed.head), ctx(landed.tree));
    git(landed.tree, 'switch', '--quiet', '--detach', 'HEAD');
    await assert.rejects(finishIssue.run([String(landed.number)], ctx(main.checkout)), (error: unknown) => error instanceof PreconditionError && error.message.includes(landed.tree) && error.message.includes(`git switch ${landed.branch}`) && !error.message.includes('stands in this clone'));
    assert.ok(existsSync(landed.tree), 'the worktree stays');
    assert.ok((await client.listBranchNames(main.checkout)).includes(landed.branch), 'the branch stays');
    git(landed.tree, 'switch', '--quiet', landed.branch);
    await finishIssue.run([String(landed.number)], ctx(main.checkout));
    assert.ok(!existsSync(landed.tree));
    await assert.rejects(finishIssue.run([String(landed.number)], ctx(main.checkout)), /stands in this clone, so nothing is removed/);
  });

  it('finds the worktree of an issue of another repository by the repository start-issue recorded', async () => {
    const number = newIssue(sibling, 'Elsewhere and finished, so that it is found', { labels: ['status/ready'] });
    await startIssue.run([sibling.full, String(number)], ctx(main.checkout));
    await assert.rejects(finishIssue.run([String(number)], ctx(main.checkout)), /no worktree of o\/r#\d+ stands/, 'the number alone means the issue of this clone');
    const tree = await treeOf(main, number);
    fixture.commit(tree, `elsewhere-${number}.txt`, 'work\n');
    await assert.rejects(finishIssue.run([sibling.full, String(number)], ctx(main.checkout)), /is not on origin\/master/);
    assert.ok(existsSync(tree));
  });
});

describe('issue-release', () => {
  // A trusted "Landed on" record of landedIn, written on an issue of world.
  function recordLanding(world: World, number: number, landedIn: World = main): void {
    fake.addComment(world.full, number, 'fake-user', composeLandedRecord({ branch: 'master', repository: parseRepository(landedIn.full), reviewedHead: 'a'.repeat(40), landedCommit: 'b'.repeat(40), reviewers: ['alice'] }, parseRepository(world.full)));
  }

  it('refuses a tag that does not exist, and writes nothing', async () => {
    const number = newIssue(main, 'Released too early, so that it is refused', { labels: ['status/testing'] });
    const before = writesOf();
    await assert.rejects(issueRelease.run(['--repo', main.full, '--tag', 'v9.9.9', String(number)], ctx(main.checkout)), /has no tag v9.9.9, so nothing is released/);
    assert.equal(writesOf(), before);
  });

  it('sets the milestone of the tag on the issues of the repository and writes "Released in" on an issue of another', async () => {
    fake.addTag(main.full, 'v1.0.0');
    const first = newIssue(main, 'Released one, so that it has the milestone', { labels: ['status/testing'] });
    const second = newIssue(main, 'Released two, so that it shares the milestone', { labels: ['status/testing'] });
    const foreign = newIssue(sibling, 'Released elsewhere, so that it gets a comment', { labels: ['status/testing'] });
    recordLanding(main, first);
    recordLanding(main, second);
    recordLanding(sibling, foreign);
    const result = await issueRelease.run(['--repo', main.full, '--tag', 'v1.0.0', String(first), String(second), `${sibling.full}#${foreign}`], ctx(main.checkout));
    assert.equal(fake.readIssue(main.full, first).milestone, 'v1.0.0');
    assert.equal(fake.readIssue(main.full, second).milestone, 'v1.0.0');
    assert.deepEqual(fake.listMilestones(main.full).filter((milestone) => milestone.title === 'v1.0.0').length, 1, 'one milestone for both');
    assert.equal(fake.readIssue(sibling.full, foreign).milestone, undefined, 'a milestone belongs to one repository');
    assert.deepEqual(commentsOf(sibling, foreign).slice(1), ['Released in o/r v1.0.0:\n'], 'after its landing');
    assert.match(result.stdout, /created the milestone v1.0.0/);

    const writes = writesOf();
    await issueRelease.run(['--repo', main.full, '--tag', 'v1.0.0', String(first), `${sibling.full}#${foreign}`], ctx(main.checkout));
    assert.equal(writesOf(), writes, 'run again, it writes nothing');
  });

  it('refuses every issue with no landing of the repository, and writes nothing (planted: a stray number)', async () => {
    fake.addTag(main.full, 'v1.2.0');
    const landed = newIssue(main, 'Landed, so that it alone could be released', { labels: ['status/testing'] });
    const stray = newIssue(main, 'Never landed, so that a release on it is refused', { labels: ['status/testing'] });
    const elsewhere = newIssue(sibling, 'Landed in its own repository, so that a release of another is refused', { labels: ['status/testing'] });
    recordLanding(main, landed);
    recordLanding(sibling, elsewhere, sibling);
    const before = writesOf();
    await assert.rejects(issueRelease.run(['--repo', main.full, '--tag', 'v1.2.0', String(landed), String(stray), `${sibling.full}#${elsewhere}`], ctx(main.checkout)),
      (error: unknown) => error instanceof PreconditionError && error.message.startsWith(`o/r#${stray}, o/sibling#${elsewhere}: no "Landed on" record of o/r since the last reopening for new work`));
    assert.equal(writesOf(), before);
    assert.equal(fake.listMilestones(main.full).some((milestone) => milestone.title === 'v1.2.0'), false, 'no milestone is made');
  });

  it('records a release after a late landing, proves it and writes nothing on a second release run', async () => {
    const number = newIssue(main, 'Landing recorded late, so that the release needs a newer record', { labels: ['status/testing'] });
    const tag = `v-late-${number}`;
    fake.addTag(main.full, tag);
    const args = ['--repo', main.full, '--tag', tag, String(number)];
    fake.addComment(main.full, number, 'fake-user', composeLandedRecord({ branch: 'master', repository: { owner: 'o', repo: 'r' }, reviewedHead: 'a'.repeat(40), landedCommit: 'b'.repeat(40), reviewers: ['alice'] }, { owner: 'o', repo: 'r' }));
    await issueRelease.run(args, ctx(main.checkout));
    const initial = writesOf();
    await issueRelease.run(args, ctx(main.checkout));
    assert.equal(writesOf(), initial, 'the milestone already follows the newest landing');

    fake.addComment(main.full, number, 'fake-user', composeLandedRecord({ branch: 'master', repository: { owner: 'o', repo: 'r' }, reviewedHead: 'c'.repeat(40), landedCommit: 'd'.repeat(40), reviewers: ['alice'] }, { owner: 'o', repo: 'r' }));
    await issueRelease.run(args, ctx(main.checkout));
    assert.equal(commentsOf(main, number).at(-1), `Released in ${main.full} ${tag}:\n`);
    assert.equal(fake.readIssue(main.full, number).milestone, tag);
    const released = writesOf();
    await issueRelease.run(args, ctx(main.checkout));
    assert.equal(writesOf(), released, 'the release comment already follows the newest landing');

    const path = join(scratch, `late-landing-${number}.md`);
    writeFileSync(path, 'Opened the page and saw the released change work.\n');
    await issueProof.run([main.full, String(number), '--environment', 'prod', '--body-file', path], ctx(main.checkout));
    assert.equal(fake.readIssue(main.full, number).state, 'closed');
  });

  it('names what is done when a later issue fails', async () => {
    fake.addTag(main.full, 'v1.1.0');
    const first = newIssue(main, 'Released first, so that it is done', { labels: ['status/testing'] });
    const second = newIssue(main, 'Released second, so that it fails', { labels: ['status/testing'] });
    recordLanding(main, first);
    recordLanding(main, second);
    fake.fail({ method: 'PATCH', path: `/repos/o/r/issues/${second}`, mode: { kind: 'status', status: 500, message: 'planted' } });
    await assert.rejects(issueRelease.run(['--repo', main.full, '--tag', 'v1.1.0', String(first), String(second)], ctx(main.checkout)), (error: unknown) => error instanceof PartialCompletionError && error.completed.includes(`o/r#${first}`));
  });

  it('refuses a call with no issue and a tag that is not given', async () => {
    await assert.rejects(issueRelease.run(['--repo', main.full, '--tag', 'v1.0.0'], ctx(main.checkout)), UsageError);
    await assert.rejects(issueRelease.run(['--repo', main.full, '1'], ctx(main.checkout)), UsageError);
  });
});

describe('issue-proof and the close as completed', () => {
  const evidence = (): string => {
    const path = join(scratch, `evidence-${Math.random().toString(16).slice(2)}.md`);
    writeFileSync(path, 'Opened the page and saw the change work.\n');
    return path;
  };
  const proofArguments = (number: number, environment = 'prod'): string[] => [main.full, String(number), '--environment', environment, '--body-file', evidence()];

  function liveTagsHarness(): RecordingHarness {
    const harness = createRecordingHarness();
    harness.readLiveTags = (checkout) => {
      harness.calls.push(`readLiveTags ${checkout}`);
      return bashHarness.readLiveTags(checkout);
    };
    return harness;
  }

  async function delivered(title: string): Promise<{ number: number; head: string }> {
    const { number, tree, head } = await worked(main, title);
    await integrateIssue.run(integrateArguments(main, number, head), ctx(tree));
    fake.addTag(main.full, `v-${number}`);
    await issueRelease.run(['--repo', main.full, '--tag', `v-${number}`, String(number)], ctx(main.checkout));
    return { number, head };
  }

  it('writes the proof of a delivered issue, sets status/done and closes it as completed', async () => {
    const { number } = await delivered('Proven after delivery, so that it closes');
    const result = await issueProof.run(proofArguments(number), ctx(main.checkout));
    const issue = fake.readIssue('o/r', number);
    assert.equal(issue.state, 'closed');
    assert.deepEqual(issue.labels, ['status/done']);
    assert.equal(issue.comments.at(-1), 'Proven on prod:\n\nOpened the page and saw the change work.\n');
    assert.match(result.stdout, /proven on prod/);
  });

  it('refuses a proof before delivery: no landing, a landing with no release after it (planted: neither)', async () => {
    const none = newIssue(main, 'Never landed, so that no proof is written', { labels: ['status/implementing'] });
    const before = writesOf();
    await assert.rejects(issueProof.run(proofArguments(none), ctx(main.checkout)), /not delivered, so nothing is proven: no "Landed on" record/);
    const { number, tree, head } = await worked(main, 'Landed only, so that no proof is written');
    await integrateIssue.run(integrateArguments(main, number, head), ctx(tree));
    const writes = writesOf();
    await assert.rejects(issueProof.run(proofArguments(number), ctx(main.checkout)), /no release of o\/r follows its landing/);
    assert.equal(writesOf(), writes);
    assert.equal(before <= writes, true);
    assert.equal(fake.readIssue('o/r', number).state, 'open');
  });

  it('counts no record of an account without write permission (planted: a stranger lands, releases and would prove)', async () => {
    const number = newIssue(main, 'Faked records, so that no proof is written', { labels: ['status/testing'] });
    const landing = composeLandedRecord({ branch: 'master', repository: { owner: 'o', repo: 'r' }, reviewedHead: 'a'.repeat(40), landedCommit: 'b'.repeat(40), reviewers: ['x'] }, { owner: 'o', repo: 'r' });
    fake.addComment('o/r', number, 'stranger', landing);
    fake.addComment('o/r', number, 'stranger', 'Released in o/r v1:\n');
    const before = writesOf();
    await assert.rejects(issueProof.run(proofArguments(number), ctx(main.checkout)), /no "Landed on" record of an account with write permission/);
    assert.equal(writesOf(), before);
  });

  it('proves and closes delivered work again after a reopening to testing, without another delivery', async () => {
    const { number } = await delivered('Reopened for missing proof, so that the delivery still counts');
    await issueProof.run(proofArguments(number), ctx(main.checkout));
    const before = fake.readIssue(main.full, number);
    await issueState.runReopen([main.full, String(number), '--status', 'testing'], ctx(main.checkout));
    await assert.rejects(issueState.runClose([main.full, String(number)], ctx(main.checkout)), /no proof that follows its landing and its last reopening/);
    await issueProof.run(proofArguments(number), ctx(main.checkout));
    const issue = fake.readIssue(main.full, number);
    assert.equal(issue.state, 'closed');
    assert.deepEqual(issue.labels, ['status/done']);
    assert.equal(issue.milestone, before.milestone);
    assert.deepEqual(issue.comments, [...before.comments, 'Proven on prod:\n\nOpened the page and saw the change work.\n']);
  });

  it('refuses a proof of work reopened to implementing after delivery, until it is delivered again', async () => {
    const { number } = await delivered('Reopened after delivery, so that the old records are stale');
    await issueProof.run(proofArguments(number), ctx(main.checkout));
    await issueState.runReopen([main.full, String(number), '--status', 'implementing'], ctx(main.checkout));
    await assert.rejects(issueProof.run(proofArguments(number), ctx(main.checkout)), /no "Landed on" record .* follows the last reopening for new work/);
    await assert.rejects(issueState.runClose([main.full, String(number)], ctx(main.checkout)), /no proof that follows its landing and its last reopening/);
    const landing = composeLandedRecord({ branch: 'master', repository: { owner: 'o', repo: 'r' }, reviewedHead: 'c'.repeat(40), landedCommit: 'd'.repeat(40), reviewers: ['x'] }, { owner: 'o', repo: 'r' });
    fake.addComment('o/r', number, 'fake-user', landing);
    await assert.rejects(issueProof.run(proofArguments(number), ctx(main.checkout)), /no release of o\/r follows its landing/);
    fake.addTag(main.full, `v-again-${number}`);
    await issueRelease.run(['--repo', main.full, '--tag', `v-again-${number}`, String(number)], ctx(main.checkout));
    await issueProof.run(proofArguments(number), ctx(main.checkout));
    assert.equal(fake.readIssue('o/r', number).state, 'closed');
  });

  it('takes a landing as the delivery where LIVE_TAGS names the environment with the pattern landed, and only that environment', async () => {
    const { number, tree, head } = await worked(main, 'Landing is delivery, so that no release is needed');
    await integrateIssue.run(integrateArguments(main, number, head), ctx(tree));
    await assert.rejects(issueProof.run(proofArguments(number, 'test'), ctx(main.checkout, { liveTags: 'prod=landed test=deploy/test/*' })), /no release of o\/r follows its landing/);
    await issueProof.run(proofArguments(number, 'prod'), ctx(main.checkout, { liveTags: 'prod=landed test=deploy/test/*' }));
    assert.equal(fake.readIssue('o/r', number).state, 'closed');
  });

  it('takes a neighbour landing as delivery by its own LIVE_TAGS from a worktree', async () => {
    const { number, tree, head } = await worked(main, 'Neighbour delivered by landing, so that the issue can be proven');
    await integrateIssue.run(integrateArguments(main, number, head), ctx(tree));
    fake.addTag(main.full, `v-${number}`);
    await issueRelease.run(['--repo', main.full, '--tag', `v-${number}`, String(number)], ctx(main.checkout));
    fake.addComment(main.full, number, 'fake-user', composeLandedRecord({ branch: 'master', repository: { owner: 'o', repo: 'sibling' }, reviewedHead: 'a'.repeat(40), landedCommit: 'b'.repeat(40), reviewers: ['alice'] }, { owner: 'o', repo: 'r' }));
    mkdirSync(join(sibling.checkout, '.ai-core'), { recursive: true });
    writeFileSync(join(sibling.checkout, '.ai-core', 'config.env'), 'LIVE_TAGS="prod=landed test=deploy/test/*"\n');
    const harness = liveTagsHarness();

    await issueProof.run(proofArguments(number), ctx(tree, { liveTags: 'prod=v*' }, harness));

    assert.equal(fake.readIssue(main.full, number).state, 'closed');
    assert.deepEqual(harness.calls, [`readLiveTags ${sibling.checkout}`]);
  });

  it('refuses a neighbour landing whose own LIVE_TAGS needs a release (planted)', async () => {
    const { number } = await delivered('Neighbour needs a release, so that the clone setting cannot exempt it');
    fake.addComment(main.full, number, 'fake-user', composeLandedRecord({ branch: 'master', repository: { owner: 'o', repo: 'sibling' }, reviewedHead: 'a'.repeat(40), landedCommit: 'b'.repeat(40), reviewers: ['alice'] }, { owner: 'o', repo: 'r' }));
    mkdirSync(join(sibling.checkout, '.ai-core'), { recursive: true });
    writeFileSync(join(sibling.checkout, '.ai-core', 'config.env'), 'LIVE_TAGS="prod=deploy/prod/* test=landed"\n');
    const harness = liveTagsHarness();
    const before = writesOf();

    await assert.rejects(issueProof.run(proofArguments(number), ctx(main.checkout, { liveTags: 'prod=landed' }, harness)), /no release of o\/sibling follows its landing/);

    assert.deepEqual(harness.calls, [`readLiveTags ${sibling.checkout}`]);
    assert.equal(writesOf(), before);
    assert.equal(fake.readIssue(main.full, number).state, 'open');
  });

  // The sibling's own reader prints what the script prints; its LIVE_TAGS names prod with the pattern command.
  function siblingReads(script: string): RecordingHarness {
    mkdirSync(join(sibling.checkout, '.ai-core'), { recursive: true });
    writeFileSync(join(sibling.checkout, '.ai-core', 'reader.sh'), `#!/usr/bin/env bash\n${script}\n`, { mode: 0o755 });
    writeFileSync(join(sibling.checkout, '.ai-core', 'config.env'), 'LIVE_TAGS="prod=command"\nLIVE_RELEASE_COMMAND=".ai-core/reader.sh"\n');
    const harness = liveTagsHarness();
    harness.readLiveRelease = (checkout, repository, environment) => {
      harness.calls.push(`readLiveRelease ${checkout} ${repository} ${environment}`);
      return bashHarness.readLiveRelease(checkout, repository, environment);
    };
    return harness;
  }
  const commitInSibling = (message: string): string => {
    git(sibling.checkout, 'commit', '--allow-empty', '-q', '-m', message);
    return git(sibling.checkout, 'rev-parse', 'HEAD');
  };
  const deliveryOf = (commit: string): string =>
    `printf '{"repository":"%s","environment":"%s","commit":"${commit}","releasedAt":"2020-01-01T00:00:00Z","source":"release 1.0.0 of o/r"}\\n' "$1" "$2"`;
  const landedInSibling = (number: number, commit: string): void => {
    fake.addComment(main.full, number, 'fake-user', composeLandedRecord({ branch: 'master', repository: { owner: 'o', repo: 'sibling' }, reviewedHead: 'a'.repeat(40), landedCommit: commit, reviewers: ['alice'] }, { owner: 'o', repo: 'r' }));
  };

  it('takes a neighbour landing as delivered where its own reader answers a delivery that holds it (planted: counted as no release before)', async () => {
    const { number } = await delivered('Pinned neighbour shipped by another release, so that its reader decides');
    const landed = commitInSibling('landed work');
    const shipped = commitInSibling('work shipped after it');
    landedInSibling(number, landed);
    const harness = siblingReads(deliveryOf(shipped));

    await issueProof.run(proofArguments(number), ctx(main.checkout, { liveTags: 'prod=v*' }, harness));

    assert.equal(fake.readIssue(main.full, number).state, 'closed');
    assert.deepEqual(harness.calls, [`readLiveTags ${sibling.checkout}`, `readLiveRelease ${sibling.checkout} o/sibling prod`]);
  });

  it('refuses a neighbour whose reader answers a delivery without the landing, no delivery or an error, and one whose record names no commit, each with its reason (planted)', async () => {
    const { number } = await delivered('Pinned neighbour not shipped yet, so that the proof waits');
    const shippedEarlier = commitInSibling('shipped before the landing');
    const landed = commitInSibling('landed after that delivery');
    landedInSibling(number, landed);
    const writes = writesOf();
    const prove = (script: string): Promise<unknown> => issueProof.run(proofArguments(number), ctx(main.checkout, { liveTags: 'prod=v*' }, siblingReads(script)));

    await assert.rejects(prove(deliveryOf(shippedEarlier)), new RegExp(`o/sibling was last delivered on prod by release 1\\.0\\.0 of o/r at 2020-01-01T00:00:00Z, which does not hold its landed commit ${landed}`));
    await assert.rejects(prove('echo null'), /the reader of o\/sibling found no completed delivery on prod/);
    await assert.rejects(prove('echo broken >&2; exit 1'), /the delivery of o\/sibling on prod could not be read: .*exited 1 for o\/sibling prod: broken/);
    fake.addComment(main.full, number, 'fake-user', 'Landed on master of o/sibling:\n\nReviewed by: alice\n');
    await assert.rejects(prove(deliveryOf(landed)), /the "Landed on" record of o\/sibling names no landed commit/);

    assert.equal(writesOf(), writes);
    assert.equal(fake.readIssue(main.full, number).state, 'open');
  });

  it('refuses a neighbour whose landed commit its checkout does not hold, and names the fetch (planted)', async () => {
    const { number } = await delivered('Pinned neighbour not fetched, so that the proof asks for a fetch');
    const shipped = commitInSibling('work shipped');
    landedInSibling(number, 'b'.repeat(40));
    const prove = issueProof.run(proofArguments(number), ctx(main.checkout, { liveTags: 'prod=v*' }, siblingReads(deliveryOf(shipped))));

    await assert.rejects(prove, new RegExp(`${sibling.checkout} has no landed commit ${'b'.repeat(40)} of o/sibling: fetch it, then prove again`));
    assert.equal(fake.readIssue(main.full, number).state, 'open');
  });

  it('refuses a missing neighbour and names the checkout it looked for', async () => {
    const { number } = await delivered('Neighbour is missing, so that the refusal names its path');
    fake.addComment(main.full, number, 'fake-user', composeLandedRecord({ branch: 'master', repository: { owner: 'o', repo: 'missing-neighbour' }, reviewedHead: 'a'.repeat(40), landedCommit: 'b'.repeat(40), reviewers: ['alice'] }, { owner: 'o', repo: 'r' }));
    const checkout = join(dirname(main.checkout), 'missing-neighbour');
    const before = writesOf();

    await assert.rejects(issueProof.run(proofArguments(number), ctx(main.checkout, { liveTags: 'prod=landed' }, liveTagsHarness())), (error: unknown) => error instanceof PreconditionError && error.message.includes(checkout));

    assert.equal(writesOf(), before);
    assert.equal(fake.readIssue(main.full, number).state, 'open');
  });

  it('needs no checkout for a landing in a harness layer', async () => {
    const { number } = await delivered('Harness layer landed, so that no neighbour is read');
    fake.addComment(main.full, number, 'fake-user', composeLandedRecord({ branch: 'master', repository: { owner: 'o', repo: 'shop-ai-core' }, reviewedHead: 'a'.repeat(40), landedCommit: 'b'.repeat(40), reviewers: ['alice'] }, { owner: 'o', repo: 'r' }));
    const harness = liveTagsHarness();

    await issueProof.run(proofArguments(number), ctx(main.checkout, { liveTags: 'prod=v*' }, harness));

    assert.equal(fake.readIssue(main.full, number).state, 'closed');
    assert.deepEqual(harness.calls, []);
  });

  // A clone of OWNER/NAME in the project folder FOLDER beside the one of o/r, whose LIVE_TAGS names prod as landed.
  function partnerClone(owner: string, name: string, ...folders: string[]): string[] {
    const remote = fixture.createRemote(owner, name);
    return folders.map((folder) => {
      const checkout = fixture.clone(remote, folder, name);
      mkdirSync(join(checkout, '.ai-core'), { recursive: true });
      writeFileSync(join(checkout, '.ai-core', 'config.env'), 'LIVE_TAGS="prod=landed"\n');
      return checkout;
    });
  }
  const landedInPartner = (number: number, owner: string, repo: string): void => {
    fake.addComment(main.full, number, 'fake-user', composeLandedRecord({ branch: 'master', repository: { owner, repo }, reviewedHead: 'a'.repeat(40), landedCommit: 'b'.repeat(40), reviewers: ['alice'] }, { owner: 'o', repo: 'r' }));
  };

  it('proves a landing whose clone lies in a project folder beside this one (planted: not a checkout before)', async () => {
    const { number } = await delivered('Partner folder landed, so that its clone is found beside the project folder');
    const [partner] = partnerClone('p', 'partner', 'project-p');
    landedInPartner(number, 'p', 'partner');
    const harness = liveTagsHarness();

    await issueProof.run(proofArguments(number), ctx(main.checkout, { liveTags: 'prod=v*' }, harness));

    assert.equal(fake.readIssue(main.full, number).state, 'closed');
    assert.deepEqual(harness.calls, [`readLiveTags ${partner}`]);
  });

  it('refuses a landing whose repository has a checkout in two folders beside the project folder, and names both', async () => {
    const { number } = await delivered('Partner cloned twice, so that no clone is guessed');
    const clones = partnerClone('q', 'partner-twice', 'project-q', 'scratch-q');
    landedInPartner(number, 'q', 'partner-twice');
    const harness = liveTagsHarness();
    const before = writesOf();

    await assert.rejects(issueProof.run(proofArguments(number), ctx(main.checkout, { liveTags: 'prod=v*' }, harness)),
      (error: unknown) => error instanceof PreconditionError && /q\/partner-twice has a checkout in more than one folder beside/.test(error.message) && clones.every((clone) => error.message.includes(clone)));

    assert.deepEqual(harness.calls, []);
    assert.equal(writesOf(), before);
    assert.equal(fake.readIssue(main.full, number).state, 'open');
  });

  it('proves a landing whose clone lies beside an unreadable folder (planted: the folder crashed the search)', async () => {
    const { number } = await delivered('Unreadable neighbour, so that the clone beside it is still found');
    const [partner, denied] = partnerClone('u', 'partner-denied', 'project-u', 'project-denied');
    landedInPartner(number, 'u', 'partner-denied');
    const harness = liveTagsHarness();
    rmSync(must(denied), { recursive: true });
    chmodSync(dirname(must(denied)), 0);
    try {
      await issueProof.run(proofArguments(number), ctx(main.checkout, { liveTags: 'prod=v*' }, harness));
    } finally {
      chmodSync(dirname(must(denied)), 0o755);
    }

    assert.equal(fake.readIssue(main.full, number).state, 'closed');
    assert.deepEqual(harness.calls, [`readLiveTags ${partner}`]);
  });

  it('refuses a neighbour directory that is another repository (planted: it declares landed)', async () => {
    const { number } = await delivered('Stranger beside the clone, so that its LIVE_TAGS is not believed');
    fake.addComment(main.full, number, 'fake-user', composeLandedRecord({ branch: 'master', repository: { owner: 'o', repo: 'lookalike' }, reviewedHead: 'a'.repeat(40), landedCommit: 'b'.repeat(40), reviewers: ['alice'] }, { owner: 'o', repo: 'r' }));
    const stranger = join(dirname(main.checkout), 'lookalike');
    git(dirname(main.checkout), 'clone', '--quiet', sibling.remote, stranger);
    mkdirSync(join(stranger, '.ai-core'), { recursive: true });
    writeFileSync(join(stranger, '.ai-core', 'config.env'), 'LIVE_TAGS="prod=landed"\n');
    const harness = liveTagsHarness();
    const before = writesOf();

    await assert.rejects(issueProof.run(proofArguments(number), ctx(main.checkout, { liveTags: 'prod=v*' }, harness)), (error: unknown) => error instanceof PreconditionError && error.message.includes(`${stranger} is not a checkout of o/lookalike`) && error.message.includes('and no folder beside'));

    assert.deepEqual(harness.calls, []);
    assert.equal(writesOf(), before);
    assert.equal(fake.readIssue(main.full, number).state, 'open');
  });

  it('writes its own proof where only an account without write permission wrote one (planted: a stranger proves first)', async () => {
    const { number } = await delivered('Proven by a stranger first, so that the real proof is still written');
    fake.addComment('o/r', number, 'stranger', composeProvenRecord('prod', 'Trust me.'));
    await issueProof.run(proofArguments(number), ctx(main.checkout));
    const issue = fake.readIssue('o/r', number);
    assert.equal(issue.state, 'closed');
    assert.equal(issue.comments.at(-1), 'Proven on prod:\n\nOpened the page and saw the change work.\n');
  });

  it('writes the proof once when a run failed after it, and closes on the second run', async () => {
    const { number } = await delivered('Closed after a failure, so that the proof stays single');
    fake.fail({ method: 'PATCH', path: `/repos/o/r/issues/${number}`, mode: { kind: 'status', status: 500, message: 'planted' } });
    await assert.rejects(issueProof.run(proofArguments(number), ctx(main.checkout)), (error: unknown) => error instanceof PartialCompletionError && /wrote the record "Proven on prod:"/.test(error.message));
    assert.equal(fake.readIssue('o/r', number).state, 'open');
    await issueProof.run(proofArguments(number), ctx(main.checkout));
    const issue = fake.readIssue('o/r', number);
    assert.equal(issue.state, 'closed');
    assert.equal(issue.comments.filter((text) => text.startsWith('Proven on')).length, 1);
  });

  it('refuses evidence that is empty, an environment that is no word and a closed issue', async () => {
    const { number } = await delivered('Refused input, so that nothing is written');
    const empty = join(scratch, 'empty.md');
    writeFileSync(empty, '\n');
    await assert.rejects(issueProof.run([main.full, String(number), '--environment', 'prod', '--body-file', empty], ctx(main.checkout)), /the evidence is empty/);
    await assert.rejects(issueProof.run(proofArguments(number, 'prod:1'), ctx(main.checkout)), UsageError);
    await assert.rejects(issueProof.run([main.full, String(number), '--environment', 'prod'], ctx(main.checkout)), UsageError);
    await issueProof.run(proofArguments(number), ctx(main.checkout));
    await assert.rejects(issueProof.run(proofArguments(number), ctx(main.checkout)), /is closed/);
  });

  it('refuses evidence with a literal email address for a public repository', async () => {
    const { number } = await delivered('Evidence with an address, so that it is refused');
    const path = join(scratch, 'address.md');
    writeFileSync(path, 'Signed in as someone@private-company.com and saw it work.\n');
    await assert.rejects(issueProof.run([main.full, String(number), '--environment', 'prod', '--body-file', path], ctx(main.checkout)), PreconditionError);
    assert.equal(fake.readIssue('o/r', number).state, 'open');
  });

  it('closes as completed with issue-close once a proof of a trusted account follows the landing (and not before)', async () => {
    const { number } = await delivered('Closed with a proof, so that close works');
    await assert.rejects(issueState.runClose([main.full, String(number)], ctx(main.checkout)), /has no proof that follows its landing/);
    fake.addComment('o/r', number, 'stranger', composeProvenRecord('prod', 'ok'));
    await assert.rejects(issueState.runClose([main.full, String(number)], ctx(main.checkout)), /has no proof/);
    fake.addComment('o/r', number, 'fake-user', composeProvenRecord('prod', 'ok'));
    const result = await issueState.runClose([main.full, String(number)], ctx(main.checkout));
    assert.match(result.stdout, /closed as completed/);
    assert.deepEqual(fake.readIssue('o/r', number).labels, ['status/done']);
    assert.equal(fake.readIssue('o/r', number).state, 'closed');
  });

  it('does not count a proof that came before the landing', async () => {
    const number = newIssue(main, 'Proven too early, so that it does not count', { labels: ['status/testing'] });
    fake.addComment('o/r', number, 'fake-user', composeProvenRecord('prod', 'too early'));
    fake.addComment('o/r', number, 'fake-user', composeLandedRecord({ branch: 'master', repository: { owner: 'o', repo: 'r' }, reviewedHead: 'a'.repeat(40), landedCommit: 'b'.repeat(40), reviewers: ['x'] }, { owner: 'o', repo: 'r' }));
    await assert.rejects(issueState.runClose([main.full, String(number)], ctx(main.checkout)), /has no proof/);
  });
});
