import { execFileSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const IDENTITY = { GIT_AUTHOR_NAME: 'Example', GIT_AUTHOR_EMAIL: 'example@example.test', GIT_COMMITTER_NAME: 'Example', GIT_COMMITTER_EMAIL: 'example@example.test' };

export function git(cwd: string, ...args: string[]): string {
  return execFileSync('git', ['-C', cwd, ...args], { encoding: 'utf8', env: { ...process.env, ...IDENTITY, GIT_TERMINAL_PROMPT: '0' } }).replace(/\n$/, '');
}

export interface GitFixture {
  readonly root: string;
  // A bare remote at <root>/<owner>/<name>.git whose default branch is master, with one commit.
  createRemote(owner: string, name: string): string;
  // A clone of the remote in <root>/<project folder>/<name>.
  clone(remote: string, projectFolder: string, name: string): string;
  commit(checkout: string, file: string, content: string): string;
  installHook(checkout: string, hook: string, script: string): void;
  dispose(): void;
}

export function createGitFixture(): GitFixture {
  const root = mkdtempSync(join(tmpdir(), 'forgejo-git-'));
  return {
    root,
    createRemote(owner, name) {
      const remote = join(root, owner, `${name}.git`);
      mkdirSync(join(root, owner), { recursive: true });
      execFileSync('git', ['init', '--bare', '--initial-branch=master', remote], { stdio: 'ignore' });
      const seed = join(root, `seed-${owner}-${name}`);
      execFileSync('git', ['clone', '--quiet', remote, seed], { stdio: 'ignore' });
      git(seed, 'checkout', '-q', '-b', 'master');
      writeFileSync(join(seed, 'README.md'), 'seed\n');
      git(seed, 'add', 'README.md');
      git(seed, 'commit', '-q', '-m', 'seed');
      git(seed, 'push', '-q', 'origin', 'master');
      return remote;
    },
    clone(remote, projectFolder, name) {
      const checkout = join(root, projectFolder, name);
      mkdirSync(join(root, projectFolder), { recursive: true });
      execFileSync('git', ['clone', '--quiet', remote, checkout], { stdio: 'ignore' });
      return checkout;
    },
    commit(checkout, file, content) {
      writeFileSync(join(checkout, file), content);
      git(checkout, 'add', file);
      git(checkout, 'commit', '-q', '-m', `change ${file}`);
      return git(checkout, 'rev-parse', 'HEAD');
    },
    installHook(checkout, hook, script) {
      const path = join(checkout, '.git', 'hooks', hook);
      writeFileSync(path, `#!/bin/sh\n${script}\n`);
      chmodSync(path, 0o755);
    },
    dispose() {
      rmSync(root, { recursive: true, force: true });
    },
  };
}
