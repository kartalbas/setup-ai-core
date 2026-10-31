import { readThread } from '../domain/issues.mts';
import { parseArguments, refuseExtra, takeIssue } from './arguments.mts';
import { lines } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: issue-thread [OWNER/REPO] NUMBER [--json]';
export const help = `${USAGE}

Reads an issue and its whole comment thread and changes nothing. Without --json it is laid out for a person;
with --json it is one object on one line (number, title, createdAt, state, labels, assignees, body,
comments with author, created_at, body and url). assignees is the list of logins, empty when nobody is assigned. A thread shorter than the issue's own comment count is refused.`;

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, { '--json': 'switch' });
  const { ref, rest } = await takeIssue(parsed.positionals, context.git, context.cwd, USAGE);
  refuseExtra(rest, USAGE);
  const thread = await readThread(context.api(), ref);
  if (parsed.switches.has('--json')) return { stdout: lines(JSON.stringify(thread)), stderr: '', exitCode: 0 };
  const text = [
    `#${thread.number} ${thread.title}`,
    `state: ${thread.state}`,
    `labels: ${thread.labels.length === 0 ? '-' : thread.labels.join(', ')}`,
    '',
    thread.body,
    ...thread.comments.flatMap((comment) => ['', `--- ${comment.author} ${comment.created_at}`, comment.body]),
  ];
  return { stdout: lines(...text), stderr: '', exitCode: 0 };
}
