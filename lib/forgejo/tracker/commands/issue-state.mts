import { afterStep, applyInOrder, editIssue, formatIssue, getIssue } from '../domain/issues.mts';
import { OPEN_STATUS_VALUES, parseStatus, replaceFamilyLabel, statusLabel } from '../domain/labels.mts';
import { PreconditionError, UsageError } from '../domain/refusals.mts';
import { parseArguments, refuseExtra, takeIssues } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const CLOSE_USAGE = 'usage: issue-close [OWNER/REPO] NUMBER... --reason completed|not-planned';
const REOPEN_USAGE = 'usage: issue-reopen [OWNER/REPO] NUMBER... --status backlog|ready|planned|implementing|review|testing';

export const closeHelp = `${CLOSE_USAGE}

--reason not-planned sets status/not-planned and closes the issue. --reason completed closes only an issue whose
delivery is proven, and a proof is written by issue-proof; this command refuses it and names that command.`;

export const reopenHelp = `${REOPEN_USAGE}

Reopens each issue with an open status. A proof written before the reopening does not close the new work.`;

// An issue completes through issue-proof, which writes the proof and closes it in one step.
function refuseCompletedClose(): never {
  throw new PreconditionError('an issue is closed as completed by issue-proof, which records the proof of its delivery; use --reason not-planned for work that is not done');
}

export async function runClose(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, { '--reason': 'value' });
  const { refs, rest } = await takeIssues(parsed.positionals, context.git, context.cwd, CLOSE_USAGE);
  refuseExtra(rest, CLOSE_USAGE);
  const reason = parsed.values.get('--reason') ?? 'completed';
  if (reason !== 'completed' && reason !== 'not-planned') throw new UsageError(`--reason must be completed or not-planned, not '${reason}'`);
  if (reason === 'completed') refuseCompletedClose();
  const api = context.api();
  const closed: string[] = [];
  await applyInOrder(
    'close issues as not planned',
    refs,
    formatIssue,
    async (ref) => {
      const issue = await getIssue(api, ref);
      await replaceFamilyLabel(api, ref, issue, statusLabel('not-planned'));
      await afterStep(`close issue ${formatIssue(ref)}`, `set ${statusLabel('not-planned')}`, () => editIssue(api, ref, { state: 'closed' }));
      closed.push(`${formatIssue(ref)} closed as not planned`);
    },
  );
  return succeeded(closed);
}

export async function runReopen(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, { '--status': 'value' });
  const { refs, rest } = await takeIssues(parsed.positionals, context.git, context.cwd, REOPEN_USAGE);
  refuseExtra(rest, REOPEN_USAGE);
  const status = parseStatus(parsed.values.get('--status') ?? '');
  if (!OPEN_STATUS_VALUES.includes(status)) throw new UsageError(`--status must be one of ${OPEN_STATUS_VALUES.join(', ')}, not '${status}'`);
  const api = context.api();
  const reopened: string[] = [];
  await applyInOrder(
    'reopen issues',
    refs,
    formatIssue,
    async (ref) => {
      const issue = await getIssue(api, ref);
      if (issue.state === 'open') throw new PreconditionError(`${formatIssue(ref)} is open`);
      await editIssue(api, ref, { state: 'open' });
      await afterStep(`reopen issue ${formatIssue(ref)}`, 'reopened it', () => replaceFamilyLabel(api, ref, issue, statusLabel(status)));
      reopened.push(`${formatIssue(ref)} reopened as ${statusLabel(status)}`);
    },
  );
  return succeeded(reopened);
}
