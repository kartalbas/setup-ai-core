import assert from 'node:assert/strict';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { after, before, describe, it } from 'node:test';
import { GitClient, GitError, parseRemoteAddress } from './git.mts';
import { createGitFixture, git } from '../testing/git-fixture.mts';
import type { GitFixture } from '../testing/git-fixture.mts';

const client = new GitClient();

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
