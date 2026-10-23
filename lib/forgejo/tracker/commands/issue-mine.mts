import { currentLogin, formatIssue, getIssue } from '../domain/issues.mts';
import { parseArguments, refuseExtra, takeIssue } from './arguments.mts';
import { lines } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: issue-mine [OWNER/REPO] NUMBER';
export const help = `${USAGE}

Exit 0 and one line when the signed-in account is among the issue's assignees. Exit 1 with a REFUSED line when
it is not, for an issue assigned to nobody as much as one assigned to somebody else. The signed-in account is
read first: a refused read of it is an error and is never taken for "assigned to nobody".`;

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, {});
  const { ref, rest } = await takeIssue(parsed.positionals, context.git, context.cwd, USAGE);
  refuseExtra(rest, USAGE);
  const api = context.api();
  const login = await currentLogin(api);
  const issue = await getIssue(api, ref);
  const name = formatIssue(ref);
  if (issue.assignees.some((assignee) => assignee.toLowerCase() === login.toLowerCase())) {
    return { stdout: lines(`${name} is assigned to @${login}.`), stderr: '', exitCode: 0 };
  }
  const refused =
    issue.assignees.length === 0
      ? `REFUSED: ${name} is assigned to nobody - the product owner assigns it before it is taken up.`
      : `REFUSED: ${name} is assigned to ${issue.assignees.map((assignee) => `@${assignee}`).join(', ')}, not to @${login} - ask them or the product owner to reassign it.`;
  return { stdout: lines(refused), stderr: '', exitCode: 1 };
}
