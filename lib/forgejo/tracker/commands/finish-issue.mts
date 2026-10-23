import { formatIssue, formatRepository, isSameRepository, parseRepository } from '../domain/issues.mts';
import { PartialCompletionError, PreconditionError } from '../domain/refusals.mts';
import { GitError } from '../git/git.mts';
import { parseArguments, refuseExtra, takeIssue } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: finish-issue [OWNER/REPO] NUMBER';
export const help = `${USAGE}

Removes the worktree of one issue and its branch once the work landed. It writes nothing to the tracker: the card
moved to testing when integrate-issue landed the work. It removes only the worktree of the issue named, only
when that worktree has no changes and its head is on the default branch of origin, and never forces a removal.
It looks at no other worktree.`;

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, {});
  const { ref, rest } = await takeIssue(parsed.positionals, context.git, context.cwd, USAGE);
  refuseExtra(rest, USAGE);
  const { git, cwd } = context;
  const main = await git.mainCheckout(cwd);
  const origin = await git.originRepository(main);

  const named = new RegExp(`^issue-${ref.number}(-.*)?$`);
  const candidates = [];
  for (const worktree of await git.listWorktrees(main)) {
    if (worktree.branch === undefined || !named.test(worktree.branch)) continue;
    const recorded = await git.getConfig(main, `branch.${worktree.branch}.issueRepository`);
    if (isSameRepository(recorded === undefined ? origin : parseRepository(recorded), ref)) candidates.push({ ...worktree, branch: worktree.branch });
  }
  const worktree = candidates[0];
  if (worktree === undefined) throw new PreconditionError(`no worktree of ${formatIssue(ref)} stands in this clone, so nothing is removed`);
  if (candidates.length > 1) throw new PreconditionError(`more than one worktree belongs to ${formatIssue(ref)}: ${candidates.map((candidate) => candidate.path).join(', ')}; which one to remove is not for this command to guess`);

  const defaultBranch = await git.defaultBranch(main);
  await git.fetchBranch(main, defaultBranch);
  if (!(await git.isClean(worktree.path))) throw new PreconditionError(`the worktree ${worktree.path} has changes, so it stays: the work in it is somebody's`);
  const head = await git.resolveCommit(worktree.path, 'HEAD');
  if (!(await git.isAncestor(main, head, `refs/remotes/origin/${defaultBranch}`))) {
    throw new PreconditionError(`the head ${head.slice(0, 7)} of ${worktree.branch} is not on origin/${defaultBranch}: the work did not land, so the worktree ${worktree.path} stays`);
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
