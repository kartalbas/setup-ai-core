import { formatIssue, formatRepository, isSameRepository, parseRepository } from '../domain/issues.mts';
import { PartialCompletionError, PreconditionError } from '../domain/refusals.mts';
import { hasTrustedLandedRecord, readTimeline } from '../domain/workflow.mts';
import { basename } from 'node:path';
import { GitError } from '../git/git.mts';
import { parseArguments, refuseExtra, takeIssue } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: finish-issue [OWNER/REPO] NUMBER';
export const help = `${USAGE}

Removes the worktree of one issue and its branch once the work landed. It writes nothing to the tracker: the card
moved to testing when integrate-issue landed the work. It removes only the worktree of the issue named, only
when that worktree has no changes, its head is on the default branch of origin and the issue carries the record
"Landed on <branch>:" of that head, written by an account with write permission, and never forces a removal.
Where the work landed and the record is missing, it removes nothing and names the integrate-issue command that
writes it. A worktree of the issue that stands detached, as a killed landing leaves it, it names with the
git switch to run in it first, and removes nothing. It looks at no other worktree.`;

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
  const worktree = candidates[0];
  if (worktree === undefined) throw new PreconditionError(`no worktree of ${formatIssue(ref)} stands in this clone, so nothing is removed`);
  if (candidates.length > 1) throw new PreconditionError(`more than one worktree belongs to ${formatIssue(ref)}: ${candidates.map((candidate) => candidate.path).join(', ')}; which one to remove is not for this command to guess`);

  if (worktree.isDetached) {
    throw new PreconditionError(`the worktree ${worktree.path} of ${formatIssue(ref)} stands detached, not on ${worktree.branch}, so nothing is removed: run git switch ${worktree.branch} in it first`);
  }

  const defaultBranch = await git.defaultBranch(main);
  await git.fetchBranch(main, defaultBranch);
  if (!(await git.isClean(worktree.path))) throw new PreconditionError(`the worktree ${worktree.path} has changes, so it stays: the work in it is somebody's`);
  const head = await git.resolveCommit(worktree.path, 'HEAD');
  if (!(await git.isAncestor(main, head, `refs/remotes/origin/${defaultBranch}`))) {
    throw new PreconditionError(`the head ${head.slice(0, 7)} of ${worktree.branch} is not on origin/${defaultBranch}: the work did not land, so the worktree ${worktree.path} stays`);
  }

  const landedCommit = await git.findLandingCommit(main, head, `refs/remotes/origin/${defaultBranch}`);
  const api = context.api();
  if (!(await hasTrustedLandedRecord(api, ref, await readTimeline(api, ref), head, landedCommit))) {
    throw new PreconditionError(
      `${formatIssue(ref)} carries no "Landed on" record of ${head}, so the worktree ${worktree.path} stays: the work is on origin/${defaultBranch}, and the record is written by integrate-issue, which merges and pushes nothing again: ` +
        `ai-core integrate-issue ${formatRepository(ref)} ${ref.number} --reviewed-by NAME --reviewed-head ${head}, run in that worktree`,
    );
  }

  await git.removeWorktree(main, worktree.path);
  try {
    await git.deleteBranch(main, worktree.branch);
  } catch (error) {
    if (error instanceof GitError) {
      throw new PartialCompletionError(`finish ${formatIssue(ref)}`, [`removed the worktree ${worktree.path}`], `the branch ${worktree.branch} stays: ${error.message}`);
    }
    throw error;
  }
  return succeeded([`${formatRepository(ref)}#${ref.number}: removed the worktree ${worktree.path} and the branch ${worktree.branch}; ${head.slice(0, 7)} is on origin/${defaultBranch}`]);
}
