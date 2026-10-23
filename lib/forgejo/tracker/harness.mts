import { execFile } from 'node:child_process';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { HarnessSteps, StepOutcome } from './commands/command.mts';

// The steps of the harness around a worktree run the harness's own Bash, so each has one spelling: the
// team modes check, init in a new worktree as bin/start-issue.sh runs it, and fast_forward_default_branch of
// lib/common.sh as bin/integrate-issue.sh runs it.

const CORE = resolve(fileURLToPath(new URL('.', import.meta.url)), '../../..');
const MAXIMUM_OUTPUT_BYTES = 16 * 1024 * 1024;

const ASSEMBLE = [
  'if (. "$1/lib/layers.sh" && harness_source_of "$2" >/dev/null); then',
  '  echo "Harness source worktree: run ai-core session-start and read its source rules."',
  'else bash "$1/bin/init.sh" "$2" --no-doctor; fi',
].join('\n');
const REFRESH = '. "$1/lib/common.sh" && fast_forward_default_branch "$2"';

function runBash(cwd: string, args: readonly string[]): Promise<StepOutcome> {
  return new Promise((done) => {
    execFile('bash', args, { cwd, maxBuffer: MAXIMUM_OUTPUT_BYTES }, (error, stdout, stderr) => {
      const said = `${stdout}${stderr}`.trim();
      done({ succeeded: error === null, output: said === '' && error !== null ? error.message : said });
    });
  });
}

export const bashHarness: HarnessSteps = {
  checkTeamModes: (cwd) => runBash(cwd, [`${CORE}/bin/team-modes-check.sh`]),
  assembleWorktree: (path) => runBash(path, ['-c', ASSEMBLE, 'assemble-worktree', CORE, path]),
  refreshCheckout: (checkout) => runBash(checkout, ['-c', REFRESH, 'refresh-checkout', CORE, checkout]),
};
