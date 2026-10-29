import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { after, before, describe, it } from 'node:test';
import { GitClient, GitError, isMovedTipRefusal, parseRemoteAddress } from './git.mts';
import { createGitFixture, git } from '../testing/git-fixture.mts';
import type { GitFixture } from '../testing/git-fixture.mts';

const client = new GitClient();

// A competing process: just before the command that deletes a branch, the branch moves to a commit nobody proved.
class MovingBranchGit extends GitClient {
  readonly moveBranch: () => void;

  constructor(moveBranch: () => void) {
    super();
    this.moveBranch = moveBranch;
  }

  override run(...call: Parameters<GitClient['run']>): ReturnType<GitClient['run']> {
    const args = call[1];
    if ((args[0] === 'update-ref' && args[1] === '-d') || (args[0] === 'branch' && args.includes('-D'))) this.moveBranch();
    return super.run(...call);
  }
}

describe('the address of a remote', () => {
  it('is read from https, scp-like and ssh spellings', () => {
    const expected = { owner: 'example-owner', repo: 'example-repo' };
    assert.deepEqual(parseRemoteAddress('https://forge.example.test/example-owner/example-repo.git'), expected);
    assert.deepEqual(parseRemoteAddress('git@forge.example.test:example-owner/example-repo'), expected);
    assert.deepEqual(parseRemoteAddress('ssh://git@forge.example.test:2222/example-owner/example-repo.git/'), expected);
    assert.deepEqual(parseRemoteAddress('/tmp/x/example-owner/example-repo.git'), expected);
  });

  it('refuses an address without owner and repository, and hides a password in the message', () => {
    assert.throws(() => parseRemoteAddress('https://user:hunter2@forge.example.test'), (error: unknown) => error instanceof GitError && !error.message.includes('hunter2'));
  });
});

describe('a checkout and its remote', () => {
  let fixture: GitFixture;
  let remote: string;
  let checkout: string;
  before(() => {
    fixture = createGitFixture();
    remote = fixture.createRemote('example-owner', 'example-repo');
    checkout = fixture.clone(remote, 'project', 'example-repo');
  });
  after(() => fixture.dispose());

  it('names its repository from the origin', async () => {
    assert.deepEqual(await client.originRepository(checkout), { owner: 'example-owner', repo: 'example-repo' });
  });

  it('lists the repositories of the clones beside it, from a worktree too, and skips what is no clone', async () => {
    const other = fixture.createRemote('example-owner', 'other-repo');
    fixture.clone(other, 'project', 'other-repo');
    mkdirSync(join(fixture.root, 'project', 'not-a-clone'));
    const noOrigin = join(fixture.root, 'project', 'no-origin');
    mkdirSync(noOrigin);
    git(noOrigin, 'init', '-q');
    const tree = join(fixture.root, 'project', '.worktrees', 'tree');
    await client.addWorktree(checkout, tree, 'issue-1-tree', 'HEAD');
    const names = (await client.listCloneOrigins(tree)).map((address) => address.repo).sort();
    assert.deepEqual(names, ['example-repo', 'other-repo']);
    await client.removeWorktree(checkout, tree);
  });

  it('reads the default branch of the remote, also after the remote renamed it', async () => {
    assert.equal(await client.defaultBranch(checkout), 'master');
    git(remote, 'symbolic-ref', 'HEAD', 'refs/heads/trunk');
    git(checkout, 'push', '-q', 'origin', 'master:trunk');
    assert.equal(await client.defaultBranch(checkout), 'trunk');
    git(remote, 'symbolic-ref', 'HEAD', 'refs/heads/master');
  });

  it('sees that the default branch moved: fetched explicitly, the old head is an ancestor and the new one is not', async () => {
    const before = await client.resolveCommit(checkout, 'HEAD');
    const second = fixture.clone(remote, 'second', 'example-repo');
    const moved = fixture.commit(second, 'moved.txt', 'moved\n');
    git(second, 'push', '-q', 'origin', 'master');
    await client.fetchBranch(checkout, 'master');
    const tip = await client.resolveCommit(checkout, 'refs/remotes/origin/master');
    assert.equal(tip, moved);
    assert.equal(await client.isAncestor(checkout, before, tip), true);
    assert.equal(await client.isAncestor(checkout, tip, before), false);
    await assert.rejects(client.resolveCommit(checkout, 'refs/remotes/origin/missing'), GitError);
  });

  it('refuses a push that a hook refuses, shows what the hook said and leaves the remote alone (planted: failing hook)', async () => {
    const work = fixture.clone(remote, 'hooked', 'example-repo');
    const head = fixture.commit(work, 'hooked.txt', 'x\n');
    const remoteBefore = git(remote, 'rev-parse', 'refs/heads/master');
    fixture.installHook(work, 'pre-push', 'echo "gate is red" >&2; exit 1');
    await assert.rejects(client.push(work, head, 'master'), (error: unknown) => error instanceof GitError && /gate is red/.test(error.message));
    assert.equal(git(remote, 'rev-parse', 'refs/heads/master'), remoteBefore);
  });

  it('shows what a hook says while the push runs, with a password in an address hidden (planted: a password)', async () => {
    const work = fixture.clone(remote, 'shown', 'example-repo');
    const head = fixture.commit(work, 'shown.txt', 'x\n');
    fixture.installHook(work, 'pre-push', `echo "checking" >&2; echo "fatal: unable to access 'https://user:hunter2@forge.example.test/o/r.git/'" >&2; exit 1`);
    const shown: string[] = [];
    await assert.rejects(client.push(work, head, 'master', (text) => shown.push(text)), GitError);
    const said = shown.join('');
    assert.match(said, /^checking\n/);
    assert.match(said, /'https:\/\/\*\*\*@forge\.example\.test\/o\/r\.git\/'\n/);
    assert.equal(said.includes('hunter2'), false);
  });

  it('shows what a hook writes to stdout while the push runs, as the push gate writes its check (planted: a check on stdout)', async () => {
    const work = fixture.clone(remote, 'stdout', 'example-repo');
    const head = fixture.commit(work, 'stdout.txt', 'x\n');
    fixture.installHook(work, 'pre-push', 'echo "check: FAIL - node required 26, observed 24"; echo "REFUSED" >&2; exit 1');
    const shown: string[] = [];
    await assert.rejects(client.push(work, head, 'master', (text) => shown.push(text)), GitError);
    const said = shown.join('');
    assert.match(said, /^check: FAIL - node required 26, observed 24$/m);
    assert.match(said, /^REFUSED$/m);
  });

  it('returns the stdout a caller parses also when it shows it (innocent case)', async () => {
    const head = git(checkout, 'rev-parse', 'HEAD');
    const shown: string[] = [];
    assert.equal((await client.run(checkout, ['rev-parse', 'HEAD'])).stdout.trim(), head);
    assert.equal((await client.run(checkout, ['rev-parse', 'HEAD'], [0], (text) => shown.push(text))).stdout.trim(), head);
    assert.equal(shown.join('').trim(), head);
  });

  it('tells a push that origin refused for a moved tip from a push that a hook refused (planted: a red hook while the remote moved, whose words look like git\'s)', async () => {
    const work = fixture.clone(remote, 'moved-tip', 'example-repo');
    const mover = fixture.clone(remote, 'moved-tip-mover', 'example-repo');
    const commit = fixture.commit(work, 'mine.txt', 'mine\n');
    // The remote moves while the hook runs and the hook accepts: origin refuses the update, which is the evidence of a move.
    fixture.installHook(work, 'pre-push', `unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; cd '${mover}' && git pull -q --rebase origin master && echo m > moved-a.txt && git add -A && git commit -qm moved-a && git push -q origin HEAD:master`);
    const refused = await client.push(work, commit, 'master').then(() => undefined, (error: unknown) => error);
    assert.ok(refused instanceof GitError);
    assert.equal(isMovedTipRefusal(refused), true, refused.stdout);
    // The remote moves while the hook runs and the hook refuses, saying words that look like a line of git: no evidence.
    git(work, 'fetch', '-q', 'origin');
    git(work, 'reset', '-q', '--hard', 'origin/master');
    const again = fixture.commit(work, 'again.txt', 'again\n');
    fixture.installHook(work, 'pre-push', `unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; cd '${mover}' && git pull -q --rebase origin master && echo m > moved-b.txt && git add -A && git commit -qm moved-b && git push -q origin HEAD:master; echo '!\tHEAD:refs/heads/master\t[rejected] (fetch first)' | sed 's/^/gate: /'; exit 1`);
    const red = await client.push(work, again, 'master').then(() => undefined, (error: unknown) => error);
    assert.ok(red instanceof GitError);
    assert.equal(isMovedTipRefusal(red), false, red.stdout);
    assert.equal(isMovedTipRefusal(new Error('not git')), false);
  });

  it('pushes a commit that no hook refuses (innocent case), and refuses a push to a remote that moved', async () => {
    const work = fixture.clone(remote, 'pushed', 'example-repo');
    const head = fixture.commit(work, 'pushed.txt', 'x\n');
    await client.push(work, head, 'master');
    assert.equal(git(remote, 'rev-parse', 'refs/heads/master'), head);
    const stale = fixture.clone(remote, 'stale', 'example-repo');
    git(stale, 'reset', '-q', '--hard', 'HEAD~1');
    const other = fixture.commit(stale, 'other.txt', 'y\n');
    await assert.rejects(client.push(stale, other, 'master'), GitError);
    assert.equal(git(remote, 'rev-parse', 'refs/heads/master'), head);
  });

  it('merges with a merge commit, and aborts a conflicting merge so that the checkout stays clean', async () => {
    const work = fixture.clone(remote, 'merging', 'example-repo');
    git(work, 'checkout', '-q', '-b', 'side');
    const side = fixture.commit(work, 'conflict.txt', 'side\n');
    git(work, 'checkout', '-q', 'master');
    fixture.commit(work, 'conflict.txt', 'main\n');
    await assert.rejects(client.merge(work, side, 'merge side'), GitError);
    assert.equal(await client.isClean(work), true);
    git(work, 'reset', '-q', '--hard', 'HEAD~1');
    fixture.commit(work, 'other.txt', 'other\n');
    const merged = await client.merge(work, side, 'merge side');
    assert.equal(git(work, 'rev-list', '--parents', '-n', '1', merged).split(' ').length, 3);
  });

  it('adds, lists and removes a worktree, and never removes one with changes in it', async () => {
    const tree = join(fixture.root, 'project', '.worktrees', 'issue-2');
    await client.addWorktree(checkout, tree, 'issue-2-work', 'refs/remotes/origin/master');
    const listed = await client.listWorktrees(checkout);
    assert.ok(listed.some((entry) => entry.path === tree && entry.branch === 'issue-2-work'));
    assert.equal(await client.currentBranch(tree), 'issue-2-work');
    writeFileSync(join(tree, 'dirty.txt'), 'x');
    assert.equal(await client.isClean(tree), false);
    await assert.rejects(client.removeWorktree(checkout, tree), GitError);
    assert.ok(existsSync(tree));
    git(tree, 'add', 'dirty.txt');
    git(tree, 'reset', '-q');
    writeFileSync(join(tree, 'dirty.txt'), '');
    await client.run(tree, ['clean', '-fdq']);
    await client.removeWorktree(checkout, tree);
    assert.ok(!existsSync(tree));
  });
});

describe('what the lifecycle commands ask of Git', () => {
  let fixture: GitFixture;
  let remote: string;
  let checkout: string;
  before(() => {
    fixture = createGitFixture();
    remote = fixture.createRemote('example-owner', 'lifecycle');
    checkout = fixture.clone(remote, 'project', 'lifecycle');
  });
  after(() => fixture.dispose());

  it('names the main checkout and the folder of the worktrees from the checkout and from a worktree of it', async () => {
    const tree = join(fixture.root, 'project', '.worktrees', 'lifecycle', 'issue-5-x');
    await client.addWorktree(checkout, tree, 'issue-5-x', 'HEAD');
    for (const place of [checkout, tree]) {
      assert.equal(await client.mainCheckout(place), checkout);
      assert.equal(await client.worktreeContainer(place), join(fixture.root, 'project', '.worktrees', 'lifecycle'));
    }
    await client.removeWorktree(checkout, tree);
  });

  it('reads a setting that is there and says nothing for one that is not', async () => {
    assert.equal(await client.getConfig(checkout, 'branch.nothing.issueRepository'), undefined);
    await client.setConfig(checkout, 'branch.nothing.issueRepository', 'example-owner/other');
    assert.equal(await client.getConfig(checkout, 'branch.nothing.issueRepository'), 'example-owner/other');
  });

  it('lists the branches of the clone and of origin, and deletes a branch only while it points at the tip it is given', async () => {
    git(checkout, 'branch', 'issue-6-landed');
    git(checkout, 'branch', 'issue-7-open');
    const landedTip = git(checkout, 'rev-parse', 'master');
    git(checkout, 'checkout', '-q', 'issue-7-open');
    fixture.commit(checkout, 'seven.txt', 'seven\n');
    git(checkout, 'checkout', '-q', 'master');
    const names = await client.listBranchNames(checkout);
    assert.ok(names.includes('issue-6-landed') && names.includes('master'));
    assert.ok(!names.some((name) => name.startsWith('origin')), 'the local branches only');
    await client.deleteBranch(checkout, 'issue-6-landed', landedTip);
    await assert.rejects(client.deleteBranch(checkout, 'issue-7-open', landedTip), /issue-7-open points at [0-9a-f]{40}, not at/);
    assert.ok((await client.listBranchNames(checkout)).includes('issue-7-open'));
  });

  it('deletes a branch only at the tip it proved, also when the branch moves between the check and the deletion (planted: a commit pushed meanwhile)', async () => {
    git(checkout, 'branch', 'issue-10-moving');
    const proved = git(checkout, 'rev-parse', 'issue-10-moving');
    const moving = new MovingBranchGit(() => {
      git(checkout, 'update-ref', 'refs/heads/issue-10-moving', git(checkout, 'commit-tree', '-p', 'issue-10-moving', '-m', 'pushed meanwhile', 'master^{tree}'));
    });
    await assert.rejects(moving.deleteBranch(checkout, 'issue-10-moving', proved), /issue-10-moving points at [0-9a-f]{40}, not at/);
    assert.ok((await client.listBranchNames(checkout)).includes('issue-10-moving'), 'the branch with the commit nobody proved survives');
  });

  it('deletes the configuration of the branch with it, leaves the other branches, and needs no configuration to delete (innocent cases)', async () => {
    git(checkout, 'branch', 'issue-11-configured');
    git(checkout, 'branch', 'issue-12-bare');
    git(checkout, 'branch', 'issue-13-neighbour');
    const tip = git(checkout, 'rev-parse', 'master');
    await client.setConfig(checkout, 'branch.issue-11-configured.remote', 'origin');
    await client.setConfig(checkout, 'branch.issue-11-configured.issueRepository', 'example-owner/other');
    await client.setConfig(checkout, 'branch.issue-13-neighbour.remote', 'origin');
    await client.deleteBranch(checkout, 'issue-11-configured', tip);
    await client.deleteBranch(checkout, 'issue-12-bare', tip);
    assert.equal(await client.getConfig(checkout, 'branch.issue-11-configured.remote'), undefined);
    assert.equal(await client.getConfig(checkout, 'branch.issue-11-configured.issueRepository'), undefined);
    assert.equal(await client.getConfig(checkout, 'branch.issue-13-neighbour.remote'), 'origin');
    assert.deepEqual((await client.listBranchNames(checkout)).filter((name) => /^issue-1[123]-/.test(name)), ['issue-13-neighbour']);
  });

  it('keeps a branch that a worktree has checked out, with its configuration', async () => {
    const tree = join(fixture.root, 'project', '.worktrees', 'lifecycle', 'issue-14-held');
    await client.addWorktree(checkout, tree, 'issue-14-held', 'HEAD');
    await client.setConfig(checkout, 'branch.issue-14-held.remote', 'origin');
    await assert.rejects(client.deleteBranch(checkout, 'issue-14-held', git(checkout, 'rev-parse', 'issue-14-held')), /issue-14-held is checked out in a worktree/);
    assert.ok((await client.listBranchNames(checkout)).includes('issue-14-held'));
    assert.equal(await client.getConfig(checkout, 'branch.issue-14-held.remote'), 'origin');
    await client.removeWorktree(checkout, tree);
  });

  it('lists the lock of a worktree with its reason, and refuses to remove a locked one (planted: a lock with and one without a reason)', async () => {
    const tree = join(fixture.root, 'project', '.worktrees', 'lifecycle', 'issue-15-locked');
    await client.addWorktree(checkout, tree, 'issue-15-locked', 'HEAD');
    const lockOf = async (): Promise<unknown> => (await client.listWorktrees(checkout)).find((entry) => entry.path === tree)?.lock;
    assert.equal(await lockOf(), undefined);
    git(checkout, 'worktree', 'lock', '--reason', 'ai-core init', tree);
    assert.deepEqual(await lockOf(), { reason: 'ai-core init' });
    await assert.rejects(client.removeWorktree(checkout, tree), GitError);
    assert.ok(existsSync(tree));
    git(checkout, 'worktree', 'unlock', tree);
    git(checkout, 'worktree', 'lock', tree);
    assert.deepEqual(await lockOf(), { reason: '' });
    git(checkout, 'worktree', 'unlock', tree);
    await client.removeWorktree(checkout, tree);
    assert.ok(!existsSync(tree));
  });

  it('lets the post-checkout hook of a new worktree lock it: the lock git takes while it adds the worktree is lifted by then', async () => {
    const tree = join(fixture.root, 'project', '.worktrees', 'lifecycle', 'issue-16-hooked');
    const answer = join(fixture.root, 'hook-lock-answer');
    fixture.installHook(checkout, 'post-checkout', `git worktree lock --reason 'ai-core init' . 2>"${answer}.err"; echo "lock rc=$?" > "${answer}"; git worktree unlock .`);
    try {
      await client.addWorktree(checkout, tree, 'issue-16-hooked', 'HEAD');
      assert.equal(readFileSync(answer, 'utf8').trim(), 'lock rc=0', readFileSync(`${answer}.err`, 'utf8'));
      assert.equal((await client.listWorktrees(checkout)).find((entry) => entry.path === tree)?.lock, undefined);
    } finally {
      rmSync(join(checkout, '.git', 'hooks', 'post-checkout'), { force: true });
    }
    await client.removeWorktree(checkout, tree);
  });

  it('asks origin for its branches by pattern, also the ones the clone never fetched', async () => {
    const work = fixture.clone(remote, 'listing', 'lifecycle');
    git(work, 'push', '-q', 'origin', 'HEAD:refs/heads/issue-8-theirs');
    git(work, 'push', '-q', 'origin', 'HEAD:refs/heads/issue-80-other');
    assert.deepEqual(await client.listRemoteBranchNames(checkout, ['issue-8', 'issue-8-*']), ['issue-8-theirs']);
    assert.deepEqual(await client.listRemoteBranchNames(checkout, ['issue-9', 'issue-9-*']), []);
  });

  it('finds the merge that brought a commit in, or the commit itself where nothing came after it', async () => {
    const work = fixture.clone(remote, 'landing', 'lifecycle');
    git(work, 'checkout', '-q', '-b', 'side');
    const side = fixture.commit(work, 'side.txt', 'side\n');
    git(work, 'checkout', '-q', 'master');
    fixture.commit(work, 'main.txt', 'main\n');
    const merged = await client.merge(work, side, 'merge side');
    fixture.commit(work, 'after.txt', 'after\n');
    assert.equal(await client.findLandingCommit(work, side, 'master'), merged);
    assert.equal(await client.findLandingCommit(work, merged, merged), merged);
  });

  it('merges in a detached worktree and discards it, whatever it holds', async () => {
    const tree = join(fixture.root, 'project', '.worktrees', 'lifecycle', 'integrate-1.test');
    await client.addDetachedWorktree(checkout, tree, 'refs/remotes/origin/master');
    assert.equal(await client.currentBranch(tree), undefined);
    writeFileSync(join(tree, 'left-behind.txt'), 'x');
    await assert.rejects(client.removeWorktree(checkout, tree), GitError);
    await client.discardWorktree(checkout, tree);
    assert.ok(!existsSync(tree));
  });

  it('replaces a branch of origin only while it holds what was read (planted: it changed meanwhile), and deletes it on the same terms', async () => {
    const work = fixture.clone(remote, 'leased', 'lifecycle');
    const first = fixture.commit(work, 'one.txt', '1\n');
    assert.equal(await client.remoteBranchTip(work, 'ci/integrate-x'), undefined);
    await client.pushWithLease(work, first, 'ci/integrate-x', undefined);
    assert.equal(await client.remoteBranchTip(work, 'ci/integrate-x'), first);
    const second = fixture.commit(work, 'two.txt', '2\n');
    await assert.rejects(client.pushWithLease(work, second, 'ci/integrate-x', undefined), GitError);
    await assert.rejects(client.pushWithLease(work, second, 'ci/integrate-x', 'a'.repeat(40)), GitError);
    await client.pushWithLease(work, second, 'ci/integrate-x', first);
    await assert.rejects(client.deleteRemoteBranch(work, 'ci/integrate-x', first), GitError);
    assert.equal(await client.remoteBranchTip(work, 'ci/integrate-x'), second);
    await client.deleteRemoteBranch(work, 'ci/integrate-x', second);
    assert.equal(await client.remoteBranchTip(work, 'ci/integrate-x'), undefined);
  });
});

describe('what an empty origin asks of Git', () => {
  let fixture: GitFixture;
  before(() => {
    fixture = createGitFixture();
  });
  after(() => fixture.dispose());

  it('is empty where origin answers and holds no branch, and is not where it holds one or cannot be asked', async () => {
    const empty = fixture.createEmptyRemote('example-owner', 'empty', 'trunk');
    const clone = fixture.cloneEmpty(empty, 'project', 'empty', 'trunk');
    assert.equal(await client.isOriginEmpty(clone), true);
    const filled = fixture.clone(fixture.createRemote('example-owner', 'filled'), 'project', 'filled');
    assert.equal(await client.isOriginEmpty(filled), false);
    git(clone, 'remote', 'set-url', 'origin', join(fixture.root, 'nowhere.git'));
    assert.equal(await client.isOriginEmpty(clone), false, 'an origin that cannot be asked is not empty');
  });

  it('names the branch the HEAD of the main checkout gives the first push, also from a worktree, and refuses one that has commits', async () => {
    const empty = fixture.createEmptyRemote('example-owner', 'named', 'trunk');
    const clone = fixture.cloneEmpty(empty, 'project', 'named', 'trunk');
    const start = await client.createStartCommit(clone, 'Start example-owner/named (#1)');
    const tree = join(fixture.root, 'project', '.worktrees', 'named', 'issue-1-tree');
    await client.addWorktree(clone, tree, 'issue-1-tree', start);
    assert.equal(await client.getUnbornDefaultBranch(tree), 'trunk', 'not the branch the worktree is on');
    fixture.commit(clone, 'local.txt', 'local\n');
    await assert.rejects(client.getUnbornDefaultBranch(tree), /the branch trunk of this clone has commits/);
  });

  it('makes a commit with the empty tree and no parent that no ref holds', async () => {
    const empty = fixture.createEmptyRemote('example-owner', 'made', 'trunk');
    const clone = fixture.cloneEmpty(empty, 'project', 'made', 'trunk');
    const start = await client.createStartCommit(clone, 'Start example-owner/made (#2)');
    assert.equal(git(clone, 'rev-list', '--max-parents=0', start), start);
    assert.equal(git(clone, 'rev-parse', `${start}^{tree}`), git(clone, 'hash-object', '-t', 'tree', '/dev/null'));
    assert.equal(git(clone, 'log', '-1', '--format=%s', start), 'Start example-owner/made (#2)');
    assert.equal(git(clone, 'for-each-ref'), '');
  });
});
