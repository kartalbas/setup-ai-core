import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { addComment, afterStep, currentLogin, explainMissingAssignment, formatIssue, formatRepository, getIssue, isSameRepository, parseRepository } from '../domain/issues.mts';
import type { Issue } from '../domain/issues.mts';
import { replaceFamilyLabel, statusLabel } from '../domain/labels.mts';
import type { StatusValue } from '../domain/labels.mts';
import { PreconditionError } from '../domain/refusals.mts';
import { composeStartedRecord, hasStartedRecord, readTimeline } from '../domain/workflow.mts';
import { parseArguments, refuseExtra, takeIssue } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: start-issue [OWNER/REPO] NUMBER';
export const help = `${USAGE}

Cuts the worktree of one issue from the fetched default branch of origin, sets status/implementing and writes the
record "Started on <branch>:" with the branch and its base. Run it in the clone the work belongs to; the issue may
be in another repository (OWNER/REPO), which is then recorded on the branch.

The issue must be open, assigned to the signed-in account and in ready, planned, implementing or review. A local
branch of this issue that is not its own worktree, an origin branch of it that has not landed under another name,
and a folder in the worktree's place refuse the run. An origin branch whose tip the default branch contains does
not: the new branch descends from it. An origin branch that has not landed, under the exact name the worktree
takes, is the issue's work: the worktree is opened on it, at its tip. Where the worktree stands already, nothing
is cut again and only the records that are missing are written. Before anything it runs the team modes check and
refuses with its lines when a mode is missing. It runs ai-core init in a new worktree, so the harness is there
before the work starts; a worktree of a harness source needs none.`;

const STARTABLE: readonly StatusValue[] = ['ready', 'planned', 'implementing', 'review'];
const SLUG_LENGTH = 40;

function slugOf(title: string): string {
  return title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, SLUG_LENGTH)
    .replace(/-+$/, '');
}

// A branch whose tip origin's default branch contains has landed: a branch cut from the default branch descends
// from it, so its push fast-forwards that branch, and it holds nothing the new worktree lacks. `onlyNamed`, where
// given, is the one name that counts.
async function listUnlandedRemoteBranches(context: CommandContext, number: number, defaultBranch: string, onlyNamed: string | undefined): Promise<string[]> {
  const { git, cwd } = context;
  const names = (await git.listRemoteBranchNames(cwd, [`issue-${number}`, `issue-${number}-*`])).filter((name) => onlyNamed === undefined || name === onlyNamed);
  const unlanded: string[] = [];
  for (const name of names) {
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
  const defaultBranch = await git.defaultBranch(cwd);
  await git.fetchBranch(cwd, defaultBranch);
  const base = await git.resolveCommit(cwd, `refs/remotes/origin/${defaultBranch}`);

  const branch = `issue-${ref.number}-${slugOf(issue.title)}`.replace(/-$/, '');
  const container = await git.worktreeContainer(cwd);
  const path = join(container, branch);
  const worktrees = await git.listWorktrees(cwd);
  const cut = worktrees.find((worktree) => worktree.branch === branch);
  if (cut !== undefined && cut.path !== path) throw new PreconditionError(`the branch ${branch} is checked out in ${cut.path}, not in ${path}`);
  const resuming = cut !== undefined;
  let opened: string | undefined;

  if (!resuming) {
    // Where the issue lives in another repository, the number alone names an unrelated issue of this clone's own:
    // a local branch is the issue's where its record names the issue's repository, and any branch where it is named
    // as the issue's branch.
    const isOtherRepository = !isSameRepository(ref, origin);
    const pattern = new RegExp(`^issue-${ref.number}(-.*)?$`);
    const local: string[] = [];
    for (const name of (await git.listBranchNames(cwd)).filter((candidate) => pattern.test(candidate))) {
      const recorded = isOtherRepository ? await git.getConfig(cwd, `branch.${name}.issueRepository`) : undefined;
      if (!isOtherRepository || name === branch || (recorded !== undefined && isSameRepository(parseRepository(recorded), ref))) local.push(name);
    }
    const remote = await listUnlandedRemoteBranches(context, ref.number, defaultBranch, isOtherRepository ? branch : undefined);
    const isWorkOfOrigin = local.length === 0 && remote.length === 1 && remote[0] === branch;
    const taken = [...local, ...remote.map((name) => `origin/${name}`)];
    if (taken.length > 0 && !isWorkOfOrigin) throw new PreconditionError(`a branch for issue ${ref.number} exists already: ${taken.join(', ')}. Use its worktree, or finish that issue first`);
    if (worktrees.some((worktree) => worktree.path === path)) throw new PreconditionError(`${path} is a worktree of another branch`);
    await mkdir(container, { recursive: true });
    if (isWorkOfOrigin) {
      opened = await git.resolveCommit(cwd, `refs/remotes/origin/${branch}`);
      await git.addWorktree(cwd, path, branch, `refs/remotes/origin/${branch}`);
      // Push and pre-push read the default branch as the upstream, as on a branch cut from it.
      await git.setConfig(cwd, `branch.${branch}.merge`, `refs/heads/${defaultBranch}`);
    } else {
      await git.addWorktree(cwd, path, branch, `refs/remotes/origin/${defaultBranch}`);
    }
    if (isOtherRepository) await git.setConfig(cwd, `branch.${branch}.issueRepository`, formatRepository(ref));
  }

  const lines = [
    resuming
      ? `Worktree ${path} stands on ${branch} already.`
      : opened !== undefined
        ? `Worktree ${path} on ${branch}, opened on origin/${branch} at ${opened}: the work origin holds and no worktree had.`
        : `Worktree ${path} on ${branch}, cut from origin/${defaultBranch} at ${base}.`,
  ];
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
