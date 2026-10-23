import { applyInOrder, formatIssue, getIssue, listAssignable, setAssignees } from '../domain/issues.mts';
import { UsageError } from '../domain/refusals.mts';
import { listOf, parseArguments, refuseExtra, takeIssues } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: issue-assign [OWNER/REPO] NUMBER... (--add LOGIN... | --remove LOGIN... | --replace LOGIN...)';
export const help = `${USAGE}

--add and --remove change the assignees named and keep the others; --replace states the whole set and cannot
be combined with them. A login that Forgejo does not offer for the repository stops the command before anything
is written. Prints the assignees each issue carries afterwards.`;

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, { '--add': 'repeat', '--remove': 'repeat', '--replace': 'repeat' });
  const add = listOf(parsed, '--add');
  const remove = listOf(parsed, '--remove');
  const replace = listOf(parsed, '--replace');
  if (add.length + remove.length + replace.length === 0) throw new UsageError('name --add, --remove or --replace: an assignment that changes nothing is a mistake');
  if (replace.length > 0 && (add.length > 0 || remove.length > 0)) throw new UsageError('--replace states the whole set, so it cannot be combined with --add or --remove');
  const { refs, rest } = await takeIssues(parsed.positionals, context.git, context.cwd, USAGE);
  refuseExtra(rest, USAGE);

  const api = context.api();
  const repository = refs[0];
  if (repository === undefined) throw new UsageError(USAGE);
  const assignable = await listAssignable(api, repository);
  const unknown = [...add, ...replace].filter((login) => !assignable.some((known) => known.toLowerCase() === login.toLowerCase()));
  if (unknown.length > 0) throw new UsageError(`Forgejo does not offer ${unknown.join(', ')} as an assignee of ${repository.owner}/${repository.repo}`);

  const reports: string[] = [];
  await applyInOrder('assign issues', refs, formatIssue, async (ref) => {
    const issue = await getIssue(api, ref);
    const same = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase();
    const target =
      replace.length > 0
        ? [...replace]
        : [...issue.assignees.filter((login) => !remove.some((gone) => same(gone, login))), ...add.filter((login) => !issue.assignees.some((have) => same(have, login)))];
    const after = await setAssignees(api, ref, target);
    reports.push(`${formatIssue(ref)} assigned to ${after.assignees.join(', ') || 'nobody'}`);
  });
  return succeeded(reports);
}
