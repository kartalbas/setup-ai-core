import type { ForgejoClient } from '../api/client.mts';
import type { GitClient } from '../git/git.mts';

// What cli.mts hands to a command. The Forgejo client is built on first use, so a command that
// needs no server (help, a refused argument) needs no settings and no token.
export interface CommandContext {
  readonly cwd: string;
  readonly api: () => ForgejoClient;
  readonly git: GitClient;
  readonly settings: {
    readonly forgejoUrl: string | undefined;
    readonly tokenCommand: string | undefined;
    readonly labelsFile: string | undefined;
    readonly assigneesFile?: string | undefined;
    // The settings of the lifecycle commands: CI_GATE, LIVE_TAGS and the seconds integrate-issue waits for checks.
    readonly ciGate?: string | undefined;
    readonly liveTags?: string | undefined;
    readonly integratePollSeconds?: string | undefined;
    readonly integrateWaitSeconds?: string | undefined;
  };
  readonly now: () => Date;
  readonly harness: HarnessSteps;
  // What the person reads while the command runs, such as the lines of a push gate; the result comes after.
  readonly stderr: (text: string) => void;
}

// The steps of the Bash harness that start-issue, integrate-issue and issue-proof take as their Bash commands do.
export interface HarnessSteps {
  checkTeamModes(cwd: string): Promise<StepOutcome>;
  // init in a new worktree, or the line that a worktree of a harness source needs none.
  assembleWorktree(path: string): Promise<StepOutcome>;
  // Fast-forwards the default branch of the checkout where it is only behind origin.
  refreshCheckout(checkout: string): Promise<StepOutcome>;
  // LIVE_TAGS as the checkout's own config.env sets it, read as the Bash harness reads it.
  readLiveTags(checkout: string): Promise<StepOutcome>;
  // The newest completed delivery of the environment as the checkout's own reader answers it, checked as the Bash
  // harness checks it: {"delivered": null} or {"delivered": {commit, releasedAt, source, ...}}.
  readLiveRelease(checkout: string, repository: string, environment: string): Promise<StepOutcome>;
  // The receipt of the checks of a landing (lib/landing-check.sh): opened before the pushes, whose Git children alone
  // are told its path; completed once the push to the ci/ branch went through and the CI of that commit was read
  // green; closed on every way out. The outcome of opening holds the path.
  openLandingCheck(cwd: string): Promise<StepOutcome>;
  completeLandingCheck(receipt: string, commit: string, ciRef: string): Promise<StepOutcome>;
  closeLandingCheck(receipt: string): Promise<StepOutcome>;
  // The mark of a harness landing (lib/landing-check.sh): opened before the pushes of a landing for the commit and the
  // refs they update, its path told to the Git children of those pushes alone, closed on every way out. The push gate
  // refuses an update of the default branch that carries none. The outcome of opening holds the path.
  openLandingMark(cwd: string, commit: string, refs: readonly string[]): Promise<StepOutcome>;
  closeLandingMark(mark: string): Promise<StepOutcome>;
  // INTEGRATE_MAX_ROUNDS (lib/landing-check.sh): the most rounds a landing makes, the first one counted, as the config.env of
  // the checkout stands at this call, never cached; the outcome holds the number, or, failed, the words that name the key.
  readLandingRounds(cwd: string): Promise<StepOutcome>;
  // Runs scripts/install.sh of the worktree, its lines shown while it runs; the outcome holds the last of them.
  installTools(worktree: string, show: (text: string) => void): Promise<StepOutcome>;
  // The page of `status --tokens` (lib/status-tokens.sh): the usage windows of the tool of the session, the pace, what an
  // issue costs, the tokens; the outcome holds the page. The issues are handed over as the card rows lib/status.mjs reads,
  // one JSON object a line, beside the status columns, one a line, under the board name the page shows.
  readTokensPage(cwd: string, itemsFile: string, columnsFile: string, board: string): Promise<StepOutcome>;
}

export interface StepOutcome {
  readonly succeeded: boolean;
  readonly output: string;
}

// A command returns its result; only cli.mts prints and exits.
export interface CommandResult {
  readonly stdout: string;
  readonly stderr: string;
  readonly exitCode: number;
}

export interface Command {
  readonly name: string;
  readonly help: string;
  readonly run: (args: readonly string[], context: CommandContext) => Promise<CommandResult>;
}

export function lines(...text: readonly string[]): string {
  return text.length === 0 ? '' : `${text.join('\n')}\n`;
}

export function succeeded(stdout: readonly string[] = [], stderr: readonly string[] = []): CommandResult {
  return { stdout: lines(...stdout), stderr: lines(...stderr), exitCode: 0 };
}

// YYYY-MM-DD in the time zone of the process, as `date +%Y-%m-%d` writes it.
export function isoDate(moment: Date): string {
  const two = (value: number): string => String(value).padStart(2, '0');
  return `${moment.getFullYear()}-${two(moment.getMonth() + 1)}-${two(moment.getDate())}`;
}
