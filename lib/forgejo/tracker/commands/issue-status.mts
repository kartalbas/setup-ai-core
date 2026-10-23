import { formatIssue, getIssue } from '../domain/issues.mts';
import { OPEN_STATUS_VALUES, parseStatus, replaceFamilyLabel, statusLabel } from '../domain/labels.mts';
import { PreconditionError, UsageError } from '../domain/refusals.mts';
import { parseArguments, refuseExtra, takeIssue } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: issue-status [OWNER/REPO] NUMBER backlog|ready|planned|implementing|review|testing';
export const help = `${USAGE}

Sets the status/ label of an open issue and changes no other label. done is written by issue-proof, which
records the proof and closes the issue; not-planned by issue-close --reason not-planned.`;

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, {});
  const { ref, rest } = await takeIssue(parsed.positionals, context.git, context.cwd, USAGE);
  const [statusText, ...extra] = rest;
  if (statusText === undefined) throw new UsageError(USAGE);
  refuseExtra(extra, USAGE);
  const status = parseStatus(statusText);
  if (status === 'done') throw new PreconditionError('done is written by issue-proof, which records the proof of the delivery and closes the issue');
  if (status === 'not-planned') throw new PreconditionError('not-planned is written by issue-close --reason not-planned');
  if (!OPEN_STATUS_VALUES.includes(status)) throw new UsageError(USAGE);
  const api = context.api();
  const issue = await getIssue(api, ref);
  if (issue.state === 'closed') throw new PreconditionError(`${formatIssue(ref)} is closed: reopen it with issue-reopen --status ${status}`);
  await replaceFamilyLabel(api, ref, issue, statusLabel(status));
  return succeeded([`${formatIssue(ref)} -> ${statusLabel(status)}`]);
}
