import type { ForgejoClient } from '../api/client.mts';
import { formatIssue, formatRepository, isSameRepository, parseRepository } from '../domain/issues.mts';
import type { IssueRef } from '../domain/issues.mts';
import { PartialCompletionError, PreconditionError } from '../domain/refusals.mts';
import { findTrustedPartLanding, hasStartedRecord, hasTrustedLandedRecord, listTrustedLandedHeads, readTimeline } from '../domain/workflow.mts';
import type { TimelineEntry } from '../domain/workflow.mts';
import { basename } from 'node:path';
import { GitError } from '../git/git.mts';
import type { GitClient } from '../git/git.mts';
import { parseArguments, refuseExtra, takeIssue } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: finish-issue [OWNER/REPO] NUMBER';
export const help = `${USAGE}

Removes the worktree of one issue and its branch once the work landed. It writes nothing to the tracker: the card
moved to testing when integrate-issue landed the work. It removes only the worktree of the issue named, only
when that worktree has no changes, its head is on the default branch of origin and the issue carries the record
"Landed on <branch>:" of that head, or of a reviewed head the worktree holds when it took the default branch in
after the landing, written by an account with write permission, and never forces a removal. A record
"Landed part on <branch>:" of that head counts once a "Landed on" record of the issue follows it, from any
repository, because the issue's last part then landed; while none follows, the worktree stays for the next part.
Where the work landed and the record is missing, it removes nothing and names the integrate-issue command that
writes it. A worktree that is locked, as ai-core init locks the one it equips, is not removed: the command names the lock and
the retry. A worktree of the issue that stands detached, as a killed landing leaves it, it names with the
git switch to run in it first, and removes nothing. It looks at no other worktree. Then it deletes the issue's
branches on origin that a "Started on" record of the issue names, that no worktree has checked out and whose tip
the default branch of origin holds, each at the tip it read; it names each one that stays. Where no worktree of
the issue stands, it does only that, and refuses when it deletes nothing.

ai-core finish-issue --sweep [--dry-run] runs the sweep of bin/finish-issue.sh instead, on this tracker as on GitHub,
because the sweep reads git alone: it removes every issue worktree whose work landed, that has no changes and that
rested for a day, and names every other one. init --all runs it.`;

// The issue's branches on origin that a "Started on" record of it names: one that no worktree has checked out and
// whose tip origin's default branch holds is deleted at that tip, and every other one stays with its reason.
async function clearOriginBranches(git: GitClient, api: ForgejoClient, main: string, ref: IssueRef, defaultBranch: string, known?: readonly TimelineEntry[]): Promise<string[]> {
  const branches = await git.listRemoteBranchNames(main, [`issue-${ref.number}`, `issue-${ref.number}-*`]);
  if (branches.length === 0) return [];
  const entries = known ?? (await readTimeline(api, ref));
  const held = (await git.listWorktrees(main)).map((worktree) => worktree.branch);
  const lines: string[] = [];
  for (const branch of branches) {
    if (!hasStartedRecord(entries, branch)) continue;
    if (held.includes(branch)) {
      lines.push(`the branch ${branch} on origin stays: a worktree has it checked out`);
      continue;
    }
    await git.fetchBranch(main, branch);
    const tip = await git.resolveCommit(main, `refs/remotes/origin/${branch}`);
    if (!(await git.isAncestor(main, tip, `refs/remotes/origin/${defaultBranch}`))) {
      lines.push(`the branch ${branch} on origin stays: it holds commits that origin/${defaultBranch} lacks`);
      continue;
    }
    try {
      await git.deleteRemoteBranch(main, branch, tip);
      lines.push(`the branch ${branch} on origin deleted: origin/${defaultBranch} holds its tip ${tip.slice(0, 7)}`);
    } catch (error) {
      if (!(error instanceof GitError)) throw error;
      lines.push(`the branch ${branch} on origin stays: it could not be deleted at ${tip.slice(0, 7)}: ${error.message}`);
    }
  }
  return lines;
}

const INIT_LOCK_REASON = 'ai-core init';

// The refusal to remove a locked worktree, in the words of finish-issue.sh.
function refuseLocked(path: string, reason: string): PreconditionError {
  const state = reason === INIT_LOCK_REASON ? 'locked by ai-core init, which is equipping it' : `locked${reason === '' ? '' : ` (${reason.replaceAll(': ', ' - ')})`}`;
  const retry =
    reason === INIT_LOCK_REASON
      ? `run it again in a moment, and where no init runs any more it was killed and git worktree unlock ${path} lifts the lock`
      : `git worktree unlock ${path} lifts the lock`;
  return new PreconditionError(`the worktree ${path} is ${state}, so nothing is removed: ${retry}`);
}

async function lockOf(git: GitClient, main: string, path: string): Promise<{ readonly reason: string } | undefined> {
  return (await git.listWorktrees(main)).find((entry) => entry.path === path)?.lock;
}

// A branch that took the default branch in after the landing stands on a later commit than the reviewed head the
// record names. Its work has landed when it holds that head and, as checked by the caller, lies wholly on the
// default branch.
async function holdsLandedHead(git: GitClient, api: ForgejoClient, main: string, ref: IssueRef, entries: readonly TimelineEntry[], head: string): Promise<boolean> {
  for (const recorded of await listTrustedLandedHeads(api, ref, entries)) {
    try {
      if (await git.isAncestor(main, recorded, head)) return true;
    } catch (error) {
      if (!(error instanceof GitError)) throw error;
    }
  }
  return false;
}

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, {});
  const { ref, rest } = await takeIssue(parsed.positionals, context.git, context.cwd, USAGE);
  refuseExtra(rest, USAGE);
  const { git, cwd } = context;
  const main = await git.mainCheckout(cwd);
  const origin = await git.originRepository(main);

  const named = new RegExp(`^issue-${ref.number}(-.*)?$`);
  const localBranches = await git.listBranchNames(main);
  const candidates = [];
  for (const worktree of await git.listWorktrees(main)) {
    // A detached worktree is the issue's when it stands in the directory of a local branch of the issue, as start-issue names them.
    const branch = worktree.branch ?? (localBranches.includes(basename(worktree.path)) ? basename(worktree.path) : undefined);
    if (branch === undefined || !named.test(branch)) continue;
    const recorded = await git.getConfig(main, `branch.${branch}.issueRepository`);
    if (isSameRepository(recorded === undefined ? origin : parseRepository(recorded), ref)) candidates.push({ ...worktree, branch, isDetached: worktree.branch === undefined });
  }
  const defaultBranch = await git.defaultBranch(main);
  await git.fetchBranch(main, defaultBranch);
  const api = context.api();
  const worktree = candidates[0];
  if (worktree === undefined) {
    const cleared = await clearOriginBranches(git, api, main, ref, defaultBranch);
    if (!cleared.some((line) => line.includes(' on origin deleted: '))) {
      throw new PreconditionError([`no worktree of ${formatIssue(ref)} stands in this clone, so nothing is removed`, ...cleared].join('; '));
    }
    return succeeded([`no worktree of ${formatIssue(ref)} stands in this clone`, ...cleared]);
  }
  if (candidates.length > 1) throw new PreconditionError(`more than one worktree belongs to ${formatIssue(ref)}: ${candidates.map((candidate) => candidate.path).join(', ')}; which one to remove is not for this command to guess`);

  if (worktree.isDetached) {
    throw new PreconditionError(`the worktree ${worktree.path} of ${formatIssue(ref)} stands detached, not on ${worktree.branch}, so nothing is removed: run git switch ${worktree.branch} in it first`);
  }

  if (worktree.lock !== undefined) throw refuseLocked(worktree.path, worktree.lock.reason);
  if (!(await git.isClean(worktree.path))) throw new PreconditionError(`the worktree ${worktree.path} has changes, so it stays: the work in it is somebody's`);
  const head = await git.resolveCommit(worktree.path, 'HEAD');
  if (!(await git.isAncestor(main, head, `refs/remotes/origin/${defaultBranch}`))) {
    throw new PreconditionError(`the head ${head.slice(0, 7)} of ${worktree.branch} is not on origin/${defaultBranch}: the work did not land, so the worktree ${worktree.path} stays`);
  }

  const landedCommit = await git.findLandingCommit(main, head, `refs/remotes/origin/${defaultBranch}`);
  const entries = await readTimeline(api, ref);
  if (!(await hasTrustedLandedRecord(api, ref, entries, head, landedCommit)) && !(await holdsLandedHead(git, api, main, ref, entries, head))) {
    const part = await findTrustedPartLanding(api, ref, entries, head, landedCommit);
    if (part === 'more to follow') {
      throw new PreconditionError(`${formatIssue(ref)} landed ${head.slice(0, 7)} as a part, and its last part has not landed yet, so the worktree ${worktree.path} stays for it`);
    }
    if (part === 'none') throw new PreconditionError(
      `${formatIssue(ref)} carries no "Landed on" record of ${head}, so the worktree ${worktree.path} stays: the work is on origin/${defaultBranch}, and the record is written by integrate-issue, which merges and pushes nothing again: ` +
        `ai-core integrate-issue ${formatRepository(ref)} ${ref.number} --reviewed-by NAME --reviewed-head ${head}, run in that worktree`,
    );
  }

  try {
    await git.removeWorktree(main, worktree.path);
  } catch (error) {
    const lock = error instanceof GitError ? await lockOf(git, main, worktree.path) : undefined;
    if (lock !== undefined) throw refuseLocked(worktree.path, lock.reason);
    throw error;
  }
  try {
    await git.deleteBranch(main, worktree.branch, head);
  } catch (error) {
    if (error instanceof GitError) {
      throw new PartialCompletionError(`finish ${formatIssue(ref)}`, [`removed the worktree ${worktree.path}`], `the branch ${worktree.branch} stays: ${error.message}`);
    }
    throw error;
  }
  return succeeded([
    `${formatRepository(ref)}#${ref.number}: removed the worktree ${worktree.path} and the branch ${worktree.branch}; ${head.slice(0, 7)} is on origin/${defaultBranch}`,
    ...(await clearOriginBranches(git, api, main, ref, defaultBranch, entries)),
  ]);
}
