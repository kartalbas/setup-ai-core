import { execFile } from 'node:child_process';
import { readdir } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';
import type { Readable } from 'node:stream';

const MAXIMUM_OUTPUT_BYTES = 64 * 1024 * 1024;
const MESSAGE_STDERR_LINES = 6;

export interface RepositoryAddress {
  readonly owner: string;
  readonly repo: string;
}

export interface Worktree {
  readonly path: string;
  readonly head: string | undefined;
  readonly branch: string | undefined;
  readonly lock: { readonly reason: string } | undefined;
}

export class GitError extends Error {
  readonly arguments: readonly string[];
  readonly exitCode: number | undefined;
  // What the failed command wrote to standard output: for a push, the porcelain lines that say what origin refused.
  readonly stdout: string;

  constructor(args: readonly string[], exitCode: number | undefined, stderr: string, stdout = '') {
    const lines = stderr.trim().split('\n').filter((line) => line !== '').slice(-MESSAGE_STDERR_LINES);
    const said = lines.map(hideCredentials).join(' | ');
    super(`git ${args[0] ?? ''}${said === '' ? '' : `: ${said}`}`);
    this.name = 'GitError';
    this.arguments = args;
    this.exitCode = exitCode;
    this.stdout = stdout;
  }
}

// Origin refused to update a ref because it holds another tip than the push started from: rejected as fetch first or
// non-fast-forward, or refused where the lock of the ref found another old value. Only a line of git's own porcelain
// shape counts, so a word of a hook that looks like one does not; with the tip origin holds now it proves a move.
const MOVED_TIP_REFUSAL = /^!\t[^\t]+\t\[(?:rejected\] \((?:fetch first|non-fast-forward)\)|remote rejected\] \((?:incorrect old value provided|failed to update ref|cannot lock ref))/m;
export function isMovedTipRefusal(error: unknown): boolean {
  return error instanceof GitError && MOVED_TIP_REFUSAL.test(error.stdout);
}

// A remote address may carry a user and a password; neither belongs in a message.
function hideCredentials(text: string): string {
  return text.replace(/(\/\/)[^/@\s]*@/g, '$1***@');
}

// Whole lines only, so that an address split across two chunks is still hidden.
export function showLines(stream: Readable, show: (text: string) => void): void {
  let pending = '';
  stream.on('data', (chunk: string | Buffer) => {
    pending += String(chunk);
    const end = pending.lastIndexOf('\n') + 1;
    if (end === 0) return;
    show(hideCredentials(pending.slice(0, end)));
    pending = pending.slice(end);
  });
  stream.on('end', () => {
    if (pending !== '') show(`${hideCredentials(pending)}\n`);
  });
}

// "owner/repo" of a remote address, whatever the host and the way the address is spelled (https,
// scp-like or ssh://), as origin_repo of lib/common.sh reads it.
export function parseRemoteAddress(address: string): RepositoryAddress {
  const trimmed = address.trim().replace(/\/+$/, '').replace(/\.git$/, '');
  const match = /[:/]([^:/]+)\/([^:/]+)$/.exec(trimmed);
  if (match?.[1] === undefined || match[2] === undefined) throw new GitError(['remote'], undefined, `the remote address ${hideCredentials(address)} names no owner and repository`);
  return { owner: match[1], repo: match[2] };
}

export class GitClient {
  // `showStderr` gets what git writes to either stream while it runs: git passes a pre-push hook's stdout to its own.
  // `environment` is added to the environment of this one git process, and of the hooks it starts, alone.
  run(cwd: string, args: readonly string[], acceptedExitCodes: readonly number[] = [0], showStderr?: (text: string) => void, environment?: Readonly<Record<string, string>>): Promise<{ stdout: string; exitCode: number }> {
    return new Promise((resolve, reject) => {
      const child = execFile(
        'git',
        ['-C', cwd, ...args],
        { maxBuffer: MAXIMUM_OUTPUT_BYTES, env: { ...process.env, GIT_TERMINAL_PROMPT: '0', LC_ALL: 'C', ...environment } },
        (error, stdout, stderr) => {
          if (error === null) {
            resolve({ stdout, exitCode: 0 });
            return;
          }
          const exitCode = typeof error.code === 'number' ? error.code : undefined;
          if (exitCode !== undefined && acceptedExitCodes.includes(exitCode)) {
            resolve({ stdout, exitCode });
            return;
          }
          reject(new GitError(args, exitCode, stderr === '' ? error.message : stderr, stdout));
        },
      );
      if (showStderr !== undefined) {
        if (child.stdout !== null) showLines(child.stdout, showStderr);
        if (child.stderr !== null) showLines(child.stderr, showStderr);
      }
    });
  }

  private async output(cwd: string, args: readonly string[]): Promise<string> {
    return (await this.run(cwd, args)).stdout.replace(/\n$/, '');
  }

  async originRepository(cwd: string): Promise<RepositoryAddress> {
    return parseRemoteAddress(await this.output(cwd, ['remote', 'get-url', 'origin']));
  }

  // The repositories of the clones that lie beside this checkout: the folders of the project folder
  // (the parent of the main checkout, also from a worktree) that are Git checkouts with an origin.
  async listCloneOrigins(cwd: string): Promise<RepositoryAddress[]> {
    const projectFolder = dirname(await this.mainCheckout(cwd));
    const found: RepositoryAddress[] = [];
    for (const entry of await readdir(projectFolder, { withFileTypes: true })) {
      if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
      const clone = join(projectFolder, entry.name);
      if (!(await this.isCheckout(clone))) continue;
      const remote = await this.run(clone, ['remote', 'get-url', 'origin'], [0, 2]);
      if (remote.exitCode === 0) found.push(parseRemoteAddress(remote.stdout));
    }
    return found;
  }

  // The checkouts named NAME in the folders beside a project folder, each with its origin: the project folders of
  // other organizations, whose clones a landing may name.
  async listCheckoutsBeside(projectFolder: string, name: string): Promise<{ path: string; origin: RepositoryAddress }[]> {
    const parent = dirname(projectFolder);
    const found: { path: string; origin: RepositoryAddress }[] = [];
    for (const entry of await readdir(parent, { withFileTypes: true })) {
      if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
      const folder = join(parent, entry.name);
      if (folder === projectFolder) continue;
      const clone = join(folder, name);
      if (!(await this.isCheckout(clone))) continue;
      const remote = await this.run(clone, ['remote', 'get-url', 'origin'], [0, 2]);
      if (remote.exitCode === 0) found.push({ path: clone, origin: parseRemoteAddress(remote.stdout) });
    }
    return found;
  }

  private async isCheckout(directory: string): Promise<boolean> {
    const top = await this.run(directory, ['rev-parse', '--show-toplevel'], [0, 128]);
    return top.exitCode === 0 && top.stdout.trim() === directory;
  }

  // The default branch of origin, asked of the remote and, where that is unreachable, origin/HEAD.
  async defaultBranch(cwd: string): Promise<string> {
    const asked = await this.run(cwd, ['ls-remote', '--symref', 'origin', 'HEAD'], [0, 128]);
    const fromRemote = /^ref: refs\/heads\/(\S+)\tHEAD$/m.exec(asked.stdout)?.[1];
    if (fromRemote !== undefined) return fromRemote;
    const local = await this.run(cwd, ['symbolic-ref', '-q', 'refs/remotes/origin/HEAD'], [0, 1, 128]);
    const fromHead = /^refs\/remotes\/origin\/(\S+)$/m.exec(local.stdout)?.[1];
    if (fromHead !== undefined) return fromHead;
    throw new GitError(['ls-remote'], undefined, 'cannot read the default branch from origin or from origin/HEAD');
  }

  async fetchBranch(cwd: string, branch: string): Promise<void> {
    await this.run(cwd, ['fetch', '--quiet', 'origin', `+refs/heads/${branch}:refs/remotes/origin/${branch}`]);
  }

  async resolveCommit(cwd: string, ref: string): Promise<string> {
    return this.output(cwd, ['rev-parse', '--verify', '--quiet', `${ref}^{commit}`]);
  }

  async isAncestor(cwd: string, ancestor: string, descendant: string): Promise<boolean> {
    return (await this.run(cwd, ['merge-base', '--is-ancestor', ancestor, descendant], [0, 1])).exitCode === 0;
  }

  // The commit on the first-parent line of `ref` that brought `commit` in: the merge that landed it, or
  // the commit itself where `ref` is at it.
  async findLandingCommit(cwd: string, commit: string, ref: string): Promise<string> {
    const path = await this.output(cwd, ['rev-list', '--first-parent', '--ancestry-path', '--reverse', `${commit}..${ref}`]);
    return path.split('\n')[0] || commit;
  }

  async getSubject(cwd: string, commit: string): Promise<string> {
    return this.output(cwd, ['log', '-1', '--format=%s', commit]);
  }

  async isClean(cwd: string): Promise<boolean> {
    return (await this.listChanges(cwd)).length === 0;
  }

  // One line per changed or untracked path, staged or not, as `git status --porcelain` spells it.
  async listChanges(cwd: string): Promise<string[]> {
    const status = await this.output(cwd, ['status', '--porcelain', '--untracked-files=all']);
    return status === '' ? [] : status.split('\n');
  }

  async currentBranch(cwd: string): Promise<string | undefined> {
    const branch = await this.run(cwd, ['symbolic-ref', '--short', '-q', 'HEAD'], [0, 1]);
    return branch.exitCode === 0 ? branch.stdout.trim() : undefined;
  }

  // The main checkout of the clone, also from one of its worktrees.
  async mainCheckout(cwd: string): Promise<string> {
    const common = await this.output(cwd, ['rev-parse', '--path-format=absolute', '--git-common-dir']);
    if (!common.endsWith('/.git')) throw new GitError(['rev-parse'], undefined, `${common} is not the .git folder of a checkout`);
    return dirname(common);
  }

  // Where the worktrees of the clone stand: .worktrees/<name of the checkout> beside the checkout, as lib/board.sh puts them.
  async worktreeContainer(cwd: string): Promise<string> {
    const main = await this.mainCheckout(cwd);
    return join(dirname(main), '.worktrees', basename(main));
  }

  async getConfig(cwd: string, key: string): Promise<string | undefined> {
    const answer = await this.run(cwd, ['config', '--get', key], [0, 1]);
    return answer.exitCode === 0 ? answer.stdout.trim() : undefined;
  }

  async setConfig(cwd: string, key: string, value: string): Promise<void> {
    await this.run(cwd, ['config', key, value]);
  }

  async listBranchNames(cwd: string): Promise<string[]> {
    const listing = await this.output(cwd, ['for-each-ref', '--format=%(refname:short)', 'refs/heads']);
    return listing.split('\n').filter((name) => name !== '');
  }

  // The branches origin holds whose names match the patterns, asked of origin itself and not of the clone's last fetch.
  async listRemoteBranchNames(cwd: string, patterns: readonly string[]): Promise<string[]> {
    const listing = await this.output(cwd, ['ls-remote', '--heads', 'origin', ...patterns.map((pattern) => `refs/heads/${pattern}`)]);
    return listing
      .split('\n')
      .map((line) => line.split('\t')[1] ?? '')
      .filter((ref) => ref.startsWith('refs/heads/'))
      .map((ref) => ref.slice('refs/heads/'.length));
  }

  async listWorktrees(cwd: string): Promise<Worktree[]> {
    const listing = await this.output(cwd, ['worktree', 'list', '--porcelain']);
    return listing
      .split('\n\n')
      .filter((block) => block.trim() !== '')
      .map((block) => {
        const lines = block.split('\n');
        const value = (key: string): string | undefined => lines.find((line) => line.startsWith(`${key} `))?.slice(key.length + 1);
        const locked = lines.find((line) => line === 'locked' || line.startsWith('locked '));
        return {
          path: value('worktree') ?? '',
          head: value('HEAD'),
          branch: value('branch')?.replace(/^refs\/heads\//, ''),
          lock: locked === undefined ? undefined : { reason: locked.slice('locked '.length) },
        };
      });
  }

  async addWorktree(cwd: string, path: string, branch: string, startPoint: string): Promise<void> {
    await this.run(cwd, ['worktree', 'add', '-b', branch, path, startPoint]);
  }

  async addDetachedWorktree(cwd: string, path: string, startPoint: string): Promise<void> {
    await this.run(cwd, ['worktree', 'add', '--quiet', '--detach', path, startPoint]);
  }

  // An ignored file the commit tracks refuses the switch: by default git overwrites it, and it may be somebody's own.
  async switchDetached(cwd: string, commit: string): Promise<void> {
    await this.run(cwd, ['switch', '--quiet', '--no-overwrite-ignore', '--detach', commit]);
  }

  async switchBranch(cwd: string, branch: string): Promise<void> {
    await this.run(cwd, ['switch', '--quiet', branch]);
  }

  // Never forced: a worktree with changes in it stays.
  async removeWorktree(cwd: string, path: string): Promise<void> {
    await this.run(cwd, ['worktree', 'remove', path]);
  }

  // For the temporary worktree of a landing, which this program made and nobody works in.
  async discardWorktree(cwd: string, path: string): Promise<void> {
    await this.run(cwd, ['worktree', 'remove', '--force', path]);
  }

  // Deletes a branch in one step that holds only while it points at the tip the caller proved landed (`branch -d`
  // would judge it by its upstream, which may lack that tip), then the configuration of the branch. A branch that
  // a worktree has checked out stays, as `branch -D` would have it.
  async deleteBranch(cwd: string, branch: string, landedTip: string): Promise<void> {
    if ((await this.listWorktrees(cwd)).some((worktree) => worktree.branch === branch)) {
      throw new GitError(['branch', '-D', branch], undefined, `${branch} is checked out in a worktree`);
    }
    try {
      await this.run(cwd, ['update-ref', '-d', `refs/heads/${branch}`, landedTip]);
    } catch (error) {
      if (!(error instanceof GitError)) throw error;
      const tip = await this.resolveCommit(cwd, `refs/heads/${branch}`).catch(() => undefined);
      if (tip !== undefined && tip !== landedTip) throw new GitError(['branch', '-D', branch], undefined, `${branch} points at ${tip}, not at ${landedTip}, the tip that landed`);
      throw error;
    }
    // Exit 128 is git saying that the branch had no configuration section.
    await this.run(cwd, ['config', '--remove-section', `branch.${branch}`], [0, 128]);
  }

  // A merge commit that names its parents; a merge that conflicts is aborted and leaves the checkout as it was.
  async merge(cwd: string, commit: string, message: string): Promise<string> {
    try {
      await this.run(cwd, ['merge', '--no-ff', '-m', message, commit]);
    } catch (error) {
      await this.run(cwd, ['merge', '--abort'], [0, 128]);
      throw error;
    }
    return this.resolveCommit(cwd, 'HEAD');
  }

  // Never forced: a remote that moved refuses it.
  async push(cwd: string, commit: string, branch: string, showStderr?: (text: string) => void, environment?: Readonly<Record<string, string>>): Promise<void> {
    await this.run(cwd, ['push', '--porcelain', 'origin', `${commit}:refs/heads/${branch}`], [0], showStderr, environment);
  }

  // The commit origin holds for the branch, asked of origin itself.
  async remoteBranchTip(cwd: string, branch: string): Promise<string | undefined> {
    const answer = await this.output(cwd, ['ls-remote', '--heads', 'origin', `refs/heads/${branch}`]);
    return answer === '' ? undefined : answer.split('\t')[0];
  }

  // Replaces the branch only while origin still holds `expected` (nothing when it is to be new).
  async pushWithLease(cwd: string, commit: string, branch: string, expected: string | undefined, showStderr?: (text: string) => void, environment?: Readonly<Record<string, string>>): Promise<void> {
    await this.run(cwd, ['push', `--force-with-lease=refs/heads/${branch}:${expected ?? ''}`, 'origin', `${commit}:refs/heads/${branch}`], [0], showStderr, environment);
  }

  async deleteRemoteBranch(cwd: string, branch: string, expected: string): Promise<void> {
    await this.run(cwd, ['push', `--force-with-lease=refs/heads/${branch}:${expected}`, 'origin', '--delete', `refs/heads/${branch}`]);
  }
}
