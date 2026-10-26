import { formatIssue, getIssue } from '../domain/issues.mts';
import { applyLabelChange, canonicalLabelName, familyOf, parsePriority, planLabelChange, priorityLabel, replaceFamilyLabel } from '../domain/labels.mts';
import { checkPublicText } from '../domain/public-text.mts';
import { UsageError } from '../domain/refusals.mts';
import { listOf, parseArguments, refuseExtra, takeIssue, takeIssues } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const LABEL_USAGE = 'usage: issue-label [OWNER/REPO] NUMBER (--add NAME... | --remove NAME... | --replace NAME...)';
const PRIORITY_USAGE = 'usage: issue-priority [OWNER/REPO] NUMBER [NUMBER...] P0|P1|P2|P3|P9';

export const labelHelp = `${LABEL_USAGE}

--add puts labels on, --remove takes them off, and --add with --remove does both. --replace names the labels an
issue is to carry in their families: for each family named, the issue's labels of that family become exactly
those given, and every other label stays. An issue carries one label of an exclusive family (status/, priority/,
type/, goal/, test/, package/), so --add of a second one is refused; use --replace. A label is added only if it exists;
one is removed whether or not it exists. status/ and priority/ labels are set by issue-status and
issue-priority, and package/ labels by issue-package. A label written type:bug is read as type/bug.`;

export const priorityHelp = `${PRIORITY_USAGE}

Sets the priority/ label of each issue named and changes no other label.`;

export async function runLabel(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, { '--add': 'repeat', '--remove': 'repeat', '--replace': 'repeat' });
  const { ref, rest } = await takeIssue(parsed.positionals, context.git, context.cwd, LABEL_USAGE);
  refuseExtra(rest, LABEL_USAGE);
  const request = { add: listOf(parsed, '--add'), remove: listOf(parsed, '--remove'), replace: listOf(parsed, '--replace') };
  for (const name of [...request.add, ...request.remove, ...request.replace].map(canonicalLabelName)) {
    const family = familyOf(name);
    if (family?.name === 'status') throw new UsageError(`${name}: the status of an issue is set by issue-status, and closed by issue-proof or issue-close`);
    if (family?.name === 'priority') throw new UsageError(`${name}: the priority of an issue is set by issue-priority`);
  }
  const api = context.api();
  await checkPublicText(api, 'issue-label', ref, [...request.add, ...request.remove, ...request.replace].join('\n'));
  const issue = await getIssue(api, ref);
  const plan = planLabelChange(issue.labels, request);
  const labels = await applyLabelChange(api, ref, issue, plan);
  return succeeded([`${formatIssue(ref)} labels: ${labels.join(', ') || 'none'}`]);
}

export async function runPriority(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, {});
  const { refs, rest } = await takeIssues(parsed.positionals, context.git, context.cwd, PRIORITY_USAGE);
  const [priorityText, ...extra] = rest;
  if (priorityText === undefined) throw new UsageError(PRIORITY_USAGE);
  refuseExtra(extra, PRIORITY_USAGE);
  const label = priorityLabel(parsePriority(priorityText));
  const api = context.api();
  const issues = [];
  for (const ref of refs) issues.push(await getIssue(api, ref));
  for (const issue of issues) await replaceFamilyLabel(api, issue.ref, issue, label);
  return succeeded(issues.map((issue) => `${formatIssue(issue.ref)} -> ${label}`));
}
