import { addComment } from '../domain/issues.mts';
import { checkPublicText } from '../domain/public-text.mts';
import { UsageError } from '../domain/refusals.mts';
import { parseArguments, readTextFile, refuseExtra, requireValue, takeIssue } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: issue-comment [OWNER/REPO] NUMBER --body-file PATH';
export const help = `${USAGE}

Adds one comment and prints its address. A comment whose answer was lost is reported as uncertain and is
never sent again. Text with a literal email address is refused for a public repository.`;

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, { '--body-file': 'value' });
  const { ref, rest } = await takeIssue(parsed.positionals, context.git, context.cwd, USAGE);
  refuseExtra(rest, USAGE);
  const body = await readTextFile(requireValue(parsed, '--body-file'));
  if (body.trim() === '') throw new UsageError('the comment is empty');
  const api = context.api();
  await checkPublicText(context, api, 'issue-comment', ref, body);
  const comment = await addComment(api, ref, body);
  return succeeded([comment.url]);
}
