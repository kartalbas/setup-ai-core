import { formatIssue, getIssue } from '../domain/issues.mts';
import { OPEN_STATUS_VALUES, parseStatus, replaceFamilyLabel, statusLabel } from '../domain/labels.mts';
import { PreconditionError, UsageError } from '../domain/refusals.mts';
import { parseArguments, refuseExtra, takeIssues } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: issue-status [OWNER/REPO] NUMBER [NUMBER...] backlog|ready|planned|implementing|review|testing';
export const help = `${USAGE}

Sets the status/ label of each open issue and changes no other label. A closed one among them refuses before
any issue changes. done is written by issue-proof, which records the proof and closes the issue; not-planned by
issue-close --reason not-planned.`;

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, {});
  const { refs, rest } = await takeIssues(parsed.positionals, context.git, context.cwd, USAGE);
  const [statusText, ...extra] = rest;
  if (statusText === undefined) throw new UsageError(USAGE);
  refuseExtra(extra, USAGE);
  const status = parseStatus(statusText);
  if (status === 'done') throw new PreconditionError('done is written by issue-proof, which records the proof of the delivery and closes the issue');
  if (status === 'not-planned') throw new PreconditionError('not-planned is written by issue-close --reason not-planned');
  if (!OPEN_STATUS_VALUES.includes(status)) throw new UsageError(USAGE);
  const api = context.api();
  const issues = [];
  for (const ref of refs) {
    const issue = await getIssue(api, ref);
    if (issue.state === 'closed') throw new PreconditionError(`${formatIssue(ref)} is closed: reopen it with issue-reopen --status ${status}`);
    issues.push(issue);
  }
  for (const issue of issues) await replaceFamilyLabel(api, issue.ref, issue, statusLabel(status));
  return succeeded(issues.map((issue) => `${formatIssue(issue.ref)} -> ${statusLabel(status)}`));
}
