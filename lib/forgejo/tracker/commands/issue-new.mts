import { composeOriginLine, createIssue } from '../domain/issues.mts';
import type { Provenance } from '../domain/issues.mts';
import { canonicalLabelName, listVisibleLabels, parsePriority, parseStatus, planLabelChange, priorityLabel, resolveLabels, statusLabel } from '../domain/labels.mts';
import { checkPublicText } from '../domain/public-text.mts';
import { UsageError } from '../domain/refusals.mts';
import { OPEN_STATUS_VALUES } from '../domain/labels.mts';
import { listOf, parseArguments, readTextFile, requireValue, takeRepository } from './arguments.mts';
import { isoDate, succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

export const help = `usage: issue-new [--repo OWNER/REPO] --title TEXT --body-file PATH --label NAME... --priority P0|P1|P2|P3|P9
                 [--status backlog|ready|planned|implementing|review|testing]
                 (--asked-by LOGIN --asked-in WHERE | --found-in WHERE)

Creates the issue with its labels, its priority/ label and its status/ label (ready unless --status says
otherwise), and prints the new issue number. At least two labels are required, one for the type of work and
one for the area. A label written type:bug is read as type/bug. The first line of the body names who asked for
the work; --found-in, for a defect found in the work, is only for a type/bug label. Text with a literal email
address is refused for a public repository.`;

const OPTIONS = {
  '--repo': 'value',
  '--title': 'value',
  '--body-file': 'value',
  '--label': 'repeat',
  '--priority': 'value',
  '--status': 'value',
  '--asked-by': 'value',
  '--asked-in': 'value',
  '--found-in': 'value',
} as const;

export interface IssueNewArguments {
  readonly repository: string | undefined;
  readonly title: string;
  readonly bodyFile: string;
  readonly labels: readonly string[];
  readonly priority: ReturnType<typeof parsePriority>;
  readonly status: ReturnType<typeof parseStatus>;
  readonly provenance: Provenance;
}

export function parseIssueNewArguments(args: readonly string[]): IssueNewArguments {
  const parsed = parseArguments(args, OPTIONS);
  if (parsed.positionals.length > 0) throw new UsageError(`unexpected '${parsed.positionals[0] ?? ''}'`);
  const labels = listOf(parsed, '--label').map(canonicalLabelName);
  if (labels.length < 2) throw new UsageError('at least two labels are required: one for the type of work, one for the area');
  const status = parseStatus(parsed.values.get('--status') ?? 'ready');
  if (!OPEN_STATUS_VALUES.includes(status)) throw new UsageError(`a new issue is open: --status must be one of ${OPEN_STATUS_VALUES.join(', ')}`);
  const askedBy = parsed.values.get('--asked-by');
  const askedIn = parsed.values.get('--asked-in');
  const foundIn = parsed.values.get('--found-in');
  let provenance: Provenance;
  if (foundIn !== undefined) {
    if (askedBy !== undefined || askedIn !== undefined) throw new UsageError('--found-in and --asked-by/--asked-in contradict each other: one says a session found a defect, the other names who said yes');
    if (!labels.includes('type/bug')) throw new UsageError('--found-in is only for a defect found in the work (label type/bug); other work needs --asked-by and --asked-in');
    provenance = { foundIn };
  } else {
    if (askedBy === undefined) throw new UsageError('--asked-by is required: the login of the person who said yes to this issue (a defect found in the work takes --found-in)');
    if (askedIn === undefined) throw new UsageError('--asked-in is required: where they said it');
    provenance = { askedBy, askedIn };
  }
  return {
    repository: parsed.values.get('--repo'),
    title: requireValue(parsed, '--title'),
    bodyFile: requireValue(parsed, '--body-file'),
    labels,
    priority: parsePriority(requireValue(parsed, '--priority')),
    status,
    provenance,
  };
}

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const input = parseIssueNewArguments(args);
  const fileBody = await readTextFile(input.bodyFile);
  const { repository } = await takeRepository(input.repository === undefined ? [] : [input.repository], context.git, context.cwd);
  const requested = [...input.labels, statusLabel(input.status), priorityLabel(input.priority)];
  planLabelChange([], { add: requested });
  const body = `${composeOriginLine(input.provenance, isoDate(context.now()))}\n\n${fileBody}`;
  const api = context.api();

  await checkPublicText(api, 'issue-new', repository, [input.title, ...input.labels, body].join('\n'));
  const labels = resolveLabels(await listVisibleLabels(api, repository), requested, repository);
  const issue = await createIssue(api, repository, { title: input.title, body, labels: labels.map((label) => ({ id: label.id, name: label.name })) });
  return succeeded([String(issue.ref.number)]);
}
