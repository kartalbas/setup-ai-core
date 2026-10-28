import { mkdir, mkdtemp } from 'node:fs/promises';
import { join } from 'node:path';
import { addComment, afterStep, commitNameOf, currentLogin, explainMissingAssignment, formatIssue, formatRepository, getIssue, isSameRepository, issueBranchName } from '../domain/issues.mts';
import type { Issue } from '../domain/issues.mts';
import { replaceFamilyLabel, statusLabel } from '../domain/labels.mts';
import type { StatusValue } from '../domain/labels.mts';
import { PreconditionError } from '../domain/refusals.mts';
import { composeStartedRecord, hasStartedRecord, readTimeline } from '../domain/workflow.mts';
import { isBranchOfIssue, parseArguments, refuseExtra, takeIssue } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: start-issue [OWNER/REPO] NUMBER';
export const help = `${USAGE}

Cuts the worktree of one issue from the fetched default branch of origin (where origin holds no branch at all, it first
starts the default branch with one empty commit "Start OWNER/REPO (#NUMBER)", pushed as a harness landing under the name the
HEAD of the clone gives it, and cuts from that), sets status/implementing and writes the
record "Started on <branch>:" with the branch and its base. Run it in the clone the work belongs to; the issue may
be in another repository (OWNER/REPO), which is then recorded on the branch.

The issue must be open, assigned to the signed-in account and in ready, planned, implementing or review. A local
branch of this issue that is not its own worktree, an origin branch of it that has not landed under another name,
and a folder in the worktree's place refuse the run. An origin branch whose tip the default branch contains does
not: the new branch descends from it. An origin branch that has not landed, under the exact name the worktree
takes, is the issue's work: the worktree is opened on it, at its tip. A branch of the same number that records another
repository, and, for an issue of another repository, one that records none and is not named as the issue's branch,
belongs to another issue and refuses nothing. Where the worktree stands already, nothing
is cut again and only the records that are missing are written. Before anything it runs the team modes check and
refuses with its lines when a mode is missing. It runs ai-core init in a new worktree, so the harness is there
before the work starts; a worktree of a harness source needs none.`;

const STARTABLE: readonly StatusValue[] = ['ready', 'planned', 'implementing', 'review'];

// A branch whose tip origin's default branch contains has landed: a branch cut from the default branch descends
// from it, so its push fast-forwards that branch, and it holds nothing the new worktree lacks. Only a branch that
// `isIssues` takes for the issue's counts.
async function listUnlandedRemoteBranches(context: CommandContext, number: number, defaultBranch: string, isIssues: (name: string) => Promise<boolean>): Promise<string[]> {
  const { git, cwd } = context;
  const unlanded: string[] = [];
  for (const name of await git.listRemoteBranchNames(cwd, [`issue-${number}`, `issue-${number}-*`])) {
    if (!(await isIssues(name))) continue;
    await git.fetchBranch(cwd, name);
    if (!(await git.isAncestor(cwd, `refs/remotes/origin/${name}`, `refs/remotes/origin/${defaultBranch}`))) unlanded.push(name);
  }
  return unlanded;
}

function statusOf(issue: Issue): string | undefined {
  return issue.labels.find((label) => label.startsWith('status/'));
}

function refuseUnreadyIssue(issue: Issue): void {
  const name = formatIssue(issue.ref);
  if (issue.state !== 'open') throw new PreconditionError(`${name} is closed: reopen it with issue-reopen --status ready before work starts`);
  const status = statusOf(issue);
  if (status === undefined) throw new PreconditionError(`${name} has no status/ label: set one with issue-status`);
  if (!STARTABLE.some((value) => statusLabel(value) === status)) {
    throw new PreconditionError(`${name} is in ${status}, and work starts from ${STARTABLE.map(statusLabel).join(', ')}`);
  }
}

// Pushes the start commit as the default branch of an empty origin under the mark of a landing, from a temporary worktree at
// the commit, because the push gate reads the HEAD it runs in and the clone has none yet, with the hooks of the clone by their
// absolute path, which that tree does not hold; then fetches it.
async function startDefaultBranch(context: CommandContext, number: number, defaultBranch: string, commit: string): Promise<void> {
  const { git, cwd } = context;
  const hooks = await git.getHooksDirectory(cwd);
  const container = await git.worktreeContainer(cwd);
  const tree = await mkdtemp(join(container, `start-${number}.`));
  let mark: string | undefined;
  try {
    await git.addDetachedWorktree(cwd, tree, commit);
    const marked = await context.harness.openLandingMark(tree, commit, [`refs/heads/${defaultBranch}`]);
    if (!marked.succeeded) throw new PreconditionError(`the mark of this push could not be made (${marked.output})`);
    mark = marked.output;
    try {
      await git.push(tree, commit, defaultBranch, context.stderr, { AI_CORE_LANDING_MARK: mark, GIT_CONFIG_COUNT: '1', GIT_CONFIG_KEY_0: 'core.hooksPath', GIT_CONFIG_VALUE_0: hooks });
    } catch (error) {
      throw new PreconditionError(`origin did not take the start commit as ${defaultBranch} (${error instanceof Error ? error.message : String(error)}): nothing was cut, and origin is as it was`);
    }
  } finally {
    if (mark !== undefined) await context.harness.closeLandingMark(mark);
    await git.discardWorktree(cwd, tree);
  }
  await git.fetchBranch(cwd, defaultBranch);
  if ((await git.resolveCommit(cwd, `refs/remotes/origin/${defaultBranch}`)) !== commit) {
    throw new PreconditionError(`origin/${defaultBranch} is not the start commit ${commit} after the push: another session started it; run start-issue again`);
  }
}

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, {});
  const { ref, rest } = await takeIssue(parsed.positionals, context.git, context.cwd, USAGE);
  refuseExtra(rest, USAGE);
  const { git, cwd } = context;
  const modes = await context.harness.checkTeamModes(cwd);
  if (!modes.succeeded) throw new PreconditionError(`${modes.output}\nthe team modes are missing - the lines above say which and how to install them`);
  const api = context.api();

  const login = await currentLogin(api);
  const issue = await getIssue(api, ref);
  refuseUnreadyIssue(issue);
  const unassigned = explainMissingAssignment(issue, login);
  if (unassigned !== undefined) throw new PreconditionError(unassigned);
  if (issue.title.trim() === '') throw new PreconditionError(`${formatIssue(ref)} has no title, so no worktree name can be built from it`);

  const origin = await git.originRepository(cwd);
  // An origin with no branch at all has nothing to cut from: its default branch is started below with a start commit made
  // here, which no ref holds until then, and which is the base of the worktree.
  const isOriginEmpty = await git.isOriginEmpty(cwd);
  let defaultBranch: string;
  let base: string;
  if (isOriginEmpty) {
    defaultBranch = await git.getUnbornDefaultBranch(cwd);
    base = await git.createStartCommit(cwd, `Start ${formatRepository(origin)} (${commitNameOf(ref, origin)})`);
  } else {
    defaultBranch = await git.defaultBranch(cwd);
    await git.fetchBranch(cwd, defaultBranch);
    base = await git.resolveCommit(cwd, `refs/remotes/origin/${defaultBranch}`);
  }

  const branch = issueBranchName(ref.number, issue.title);
  const container = await git.worktreeContainer(cwd);
  const path = join(container, branch);
  const worktrees = await git.listWorktrees(cwd);
  const cut = worktrees.find((worktree) => worktree.branch === branch);
  if (cut !== undefined && cut.path !== path) throw new PreconditionError(`the branch ${branch} is checked out in ${cut.path}, not in ${path}`);
  const resuming = cut !== undefined;
  let opened: string | undefined;
  const lines: string[] = [];

  if (!resuming) {
    // The number alone names an unrelated issue in each repository: a branch of it is the issue's as isBranchOfIssue says.
    const isOtherRepository = !isSameRepository(ref, origin);
    const isIssues = (name: string): Promise<boolean> => isBranchOfIssue(git, cwd, name, ref, origin, branch);
    const pattern = new RegExp(`^issue-${ref.number}(-.*)?$`);
    const local: string[] = [];
    for (const name of (await git.listBranchNames(cwd)).filter((candidate) => pattern.test(candidate))) {
      if (await isIssues(name)) local.push(name);
    }
    const remote = await listUnlandedRemoteBranches(context, ref.number, defaultBranch, isIssues);
    const isWorkOfOrigin = local.length === 0 && remote.length === 1 && remote[0] === branch;
    const taken = [...local, ...remote.map((name) => `origin/${name}`)];
    if (taken.length > 0 && !isWorkOfOrigin) throw new PreconditionError(`a branch for issue ${ref.number} exists already: ${taken.join(', ')}. Use its worktree, or finish that issue first`);
    if (worktrees.some((worktree) => worktree.path === path)) throw new PreconditionError(`${path} is a worktree of another branch`);
    await mkdir(container, { recursive: true });
    if (isOriginEmpty) {
      await startDefaultBranch(context, ref.number, defaultBranch, base);
      lines.push(`Started ${defaultBranch} of the empty ${formatRepository(origin)} with the start commit ${base}.`);
    }
    if (isWorkOfOrigin) {
      opened = await git.resolveCommit(cwd, `refs/remotes/origin/${branch}`);
      await git.addWorktree(cwd, path, branch, `refs/remotes/origin/${branch}`);
    } else {
      await git.addWorktree(cwd, path, branch, `refs/remotes/origin/${defaultBranch}`);
    }
    // A plain git push goes to the branch of the issue and pre-push in a terminal reads it, never the default branch,
    // which only a landing updates; git set the upstream to the branch it was cut from.
    await git.setConfig(cwd, `branch.${branch}.remote`, 'origin');
    await git.setConfig(cwd, `branch.${branch}.merge`, `refs/heads/${branch}`);
    if (isOtherRepository) await git.setConfig(cwd, `branch.${branch}.issueRepository`, formatRepository(ref));
  }

  lines.push(
    resuming
      ? `Worktree ${path} stands on ${branch} already.`
      : opened !== undefined
        ? `Worktree ${path} on ${branch}, opened on origin/${branch} at ${opened}: the work origin holds and no worktree had.`
        : `Worktree ${path} on ${branch}, cut from origin/${defaultBranch} at ${base}.`,
  );
  const warnings: string[] = [];
  if (!resuming) {
    const assembled = await context.harness.assembleWorktree(path);
    if (assembled.output !== '') lines.push(assembled.output);
    if (!assembled.succeeded) warnings.push(`the harness is NOT complete in the worktree: run 'ai-core init ${path} --no-doctor' before you start`);
  }
  await afterStep(
    `record the start of issue ${formatIssue(ref)}`,
    `${resuming ? 'found' : opened !== undefined ? 'opened' : 'cut'} the worktree ${path} on ${branch}`,
    async () => {
      await replaceFamilyLabel(api, ref, issue, statusLabel('implementing'));
      const entries = await readTimeline(api, ref);
      if (hasStartedRecord(entries, branch)) return;
      await addComment(api, ref, composeStartedRecord({ branch, baseBranch: defaultBranch, baseCommit: base }));
    },
  );
  lines.push(`${formatIssue(ref)} -> ${statusLabel('implementing')}; recorded "Started on ${branch}:"`);
  if (!isSameRepository(ref, origin)) lines.push(`The issue lives in ${formatRepository(ref)}: recorded on ${branch}, where integrate-issue and finish-issue read it.`);
  lines.push(`Read the issue: ai-core issue-thread ${formatRepository(ref)} ${ref.number}`);
  return succeeded(lines, warnings);
}
