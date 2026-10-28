import { execFile, spawn } from 'node:child_process';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { HarnessSteps, StepOutcome } from './commands/command.mts';
import { showLines } from './git/git.mts';

// The steps of the harness around a worktree run the harness's own Bash, so each has one spelling: the
// team modes check, init in a new worktree as bin/start-issue.sh runs it, fast_forward_default_branch of
// lib/common.sh as bin/integrate-issue.sh runs it, and live_tags_declaration and the read of
// lib/live-release.sh as bin/status.sh runs them, issue_mention_pattern of lib/common.sh as lib/board.sh reads the commits
// of an issue with it, find_commit_naming_issue of lib/common.sh, and the receipt of the checks of a landing, lib/landing-check.sh,
// as bin/integrate-issue.sh runs it, its mark of a harness landing, the most rounds of a landing, INTEGRATE_MAX_ROUNDS, and the landing lock of the clone, lib/landing-lock.sh, as bin/integrate-issue.sh takes it. The install of a merged tree runs the repository's own
// scripts/install.sh, as bin/integrate-issue.sh runs it. The page of status --tokens is lib/status-tokens.sh.

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
const COMMIT_NAMING_ISSUE = '. "$1/lib/common.sh" && find_commit_naming_issue "$2" "$3" "$4" "$5"';

// `answer` stdout reads a successful step's output from standard output alone, for a step whose output is a value:
// a warning on standard error is no part of it.
function runBash(cwd: string, args: readonly string[], answer: 'both' | 'stdout' = 'both'): Promise<StepOutcome> {
  return new Promise((done) => {
    execFile('bash', args, { cwd, maxBuffer: MAXIMUM_OUTPUT_BYTES }, (error, stdout, stderr) => {
      const said = (answer === 'stdout' && error === null ? stdout : `${stdout}${stderr}`).trim();
      done({ succeeded: error === null, output: said === '' && error !== null ? error.message : said });
    });
  });
}

// A step whose lines are shown while it runs; its outcome holds the last `tailLines` of them.
function runShown(cwd: string, args: readonly string[], show: (text: string) => void, tailLines: number): Promise<StepOutcome> {
  return new Promise((done) => {
    const child = spawn('bash', args, { cwd });
    const tail: string[] = [];
    const keep = (text: string): void => {
      show(text);
      tail.push(...text.split('\n').filter((line) => line !== ''));
      tail.splice(0, Math.max(0, tail.length - tailLines));
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
  readLiveRelease: (checkout, repository, environment) => runBash(checkout, [`${CORE}/lib/live-release.sh`, 'read', checkout, repository, environment]),
  findCommitNamingIssue: (cwd, ref, issueRepository, number, commitRepository) =>
    runBash(cwd, ['-c', COMMIT_NAMING_ISSUE, 'find-commit-naming-issue', CORE, ref, issueRepository, String(number), commitRepository], 'stdout'),
  openLandingCheck: (cwd) => runBash(cwd, [`${CORE}/lib/landing-check.sh`, 'open'], 'stdout'),
  completeLandingCheck: (receipt, commit, ciRef) => runBash(CORE, [`${CORE}/lib/landing-check.sh`, 'complete', receipt, commit, ciRef]),
  closeLandingCheck: (receipt) => runBash(CORE, [`${CORE}/lib/landing-check.sh`, 'close', receipt]),
  openLandingMark: (cwd, commit, refs) => runBash(cwd, [`${CORE}/lib/landing-check.sh`, 'mark', cwd, commit, ...refs], 'stdout'),
  closeLandingMark: (mark) => runBash(CORE, [`${CORE}/lib/landing-check.sh`, 'unmark', mark]),
  readLandingRounds: (cwd) => runBash(cwd, [`${CORE}/lib/landing-check.sh`, 'rounds'], 'stdout'),
  takeLandingLock: (cwd, issue, branch, show) => runShown(cwd, [`${CORE}/lib/landing-lock.sh`, 'take', cwd, String(process.pid), issue, branch], show, 1),
  releaseLandingLock: (cwd) => runBash(cwd, [`${CORE}/lib/landing-lock.sh`, 'release', cwd, String(process.pid)]),
  installTools: (worktree, show) => runShown(worktree, ['scripts/install.sh'], show, INSTALL_TAIL_LINES),
  readTokensPage: (cwd, itemsFile, columnsFile, board) => runBash(cwd, [`${CORE}/lib/status-tokens.sh`, itemsFile, columnsFile, board]),
};
