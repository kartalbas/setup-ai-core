import { execFile, spawn } from 'node:child_process';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { HarnessSteps, StepOutcome } from './commands/command.mts';
import { showLines } from './git/git.mts';

// The steps of the harness around a worktree run the harness's own Bash, so each has one spelling: the
// team modes check, init in a new worktree as bin/start-issue.sh runs it, fast_forward_default_branch of
// lib/common.sh as bin/integrate-issue.sh runs it, and live_tags_declaration of lib/live-release.sh as
// bin/status.sh runs it. The install of a merged tree runs the repository's own scripts/install.sh, as
// bin/integrate-issue.sh runs it.

const CORE = resolve(fileURLToPath(new URL('.', import.meta.url)), '../../..');
const MAXIMUM_OUTPUT_BYTES = 16 * 1024 * 1024;
const INSTALL_TAIL_LINES = 20;

const ASSEMBLE = [
  'if (. "$1/lib/layers.sh" && harness_source_of "$2" >/dev/null); then',
  '  echo "Harness source worktree: run ai-core session-start and read its source rules."',
  'else bash "$1/bin/init.sh" "$2" --no-doctor; fi',
].join('\n');
const REFRESH = '. "$1/lib/common.sh" && fast_forward_default_branch "$2"';
const LIVE_TAGS = '. "$1/lib/common.sh" && . "$1/lib/live-release.sh" && live_tags_declaration "$2"';

function runBash(cwd: string, args: readonly string[]): Promise<StepOutcome> {
  return new Promise((done) => {
    execFile('bash', args, { cwd, maxBuffer: MAXIMUM_OUTPUT_BYTES }, (error, stdout, stderr) => {
      const said = `${stdout}${stderr}`.trim();
      done({ succeeded: error === null, output: said === '' && error !== null ? error.message : said });
    });
  });
}

function runInstall(worktree: string, show: (text: string) => void): Promise<StepOutcome> {
  return new Promise((done) => {
    const child = spawn('bash', ['scripts/install.sh'], { cwd: worktree });
    const tail: string[] = [];
    const keep = (text: string): void => {
      show(text);
      tail.push(...text.split('\n').filter((line) => line !== ''));
      tail.splice(0, Math.max(0, tail.length - INSTALL_TAIL_LINES));
    };
    showLines(child.stdout, keep);
    showLines(child.stderr, keep);
    child.on('error', (error) => done({ succeeded: false, output: error.message }));
    child.on('close', (status) => done({ succeeded: status === 0, output: tail.join('\n') }));
  });
}

export const bashHarness: HarnessSteps = {
  checkTeamModes: (cwd) => runBash(cwd, [`${CORE}/bin/team-modes-check.sh`]),
  assembleWorktree: (path) => runBash(path, ['-c', ASSEMBLE, 'assemble-worktree', CORE, path]),
  refreshCheckout: (checkout) => runBash(checkout, ['-c', REFRESH, 'refresh-checkout', CORE, checkout]),
  readLiveTags: (checkout) => runBash(checkout, ['-c', LIVE_TAGS, 'read-live-tags', CORE, checkout]),
  installTools: runInstall,
};
