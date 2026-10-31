import { editIssue, formatIssue, getIssue, keepOriginLine } from '../domain/issues.mts';
import { checkPublicText } from '../domain/public-text.mts';
import { UsageError } from '../domain/refusals.mts';
import { parseArguments, readTextFile, refuseExtra, takeIssue } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: issue-edit [OWNER/REPO] NUMBER [--title TEXT] [--body-file PATH]';
export const help = `${USAGE}

Changes the title and the body of an issue; at least one is required. The first line of the body, which names
who asked for the work or the address an issue was moved from, is kept: where the new body does not open with
such a line, the issue's own is put back. Text with a literal email address is refused for a public repository.`;

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, { '--title': 'value', '--body-file': 'value' });
  const { ref, rest } = await takeIssue(parsed.positionals, context.git, context.cwd, USAGE);
  refuseExtra(rest, USAGE);
  const title = parsed.values.get('--title');
  const bodyFile = parsed.values.get('--body-file');
  if (title === undefined && bodyFile === undefined) throw new UsageError('name a --title or a --body-file: an edit that changes nothing is a mistake');
  if (title === '') throw new UsageError('--title is empty');
  const newBody = bodyFile === undefined ? undefined : await readTextFile(bodyFile);
  const api = context.api();

  let body = newBody;
  let kept = false;
  if (newBody !== undefined) {
    const current = await getIssue(api, ref);
    ({ body, kept } = keepOriginLine(current.body, newBody));
  }
  await checkPublicText(context, api, 'issue-edit', ref, [title ?? '', body ?? ''].join('\n'));
  await editIssue(api, ref, { ...(title === undefined ? {} : { title }), ...(body === undefined ? {} : { body }) });
  return succeeded([`${formatIssue(ref)} edited`], kept ? ['the first line of the issue was kept: the new body did not open with one'] : []);
}
