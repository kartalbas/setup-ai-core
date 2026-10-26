import type { ForgejoClient } from '../api/client.mts';
import { afterStep, applyInOrder, editIssue, formatIssue, getIssue } from '../domain/issues.mts';
import type { Issue, IssueRef } from '../domain/issues.mts';
import { OPEN_STATUS_VALUES, parseStatus, replaceFamilyLabel, statusLabel } from '../domain/labels.mts';
import { PreconditionError, UsageError } from '../domain/refusals.mts';
import { findCurrentProof, holdsNoLandedRecord, readIssueHistory, readTimeline } from '../domain/workflow.mts';
import { findLandedCommitOf, parseArguments, refuseExtra, takeIssues } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const CLOSE_USAGE = 'usage: issue-close [OWNER/REPO] NUMBER... --reason completed|not-planned';
const REOPEN_USAGE = 'usage: issue-reopen [OWNER/REPO] NUMBER... --status backlog|ready|planned|implementing|review|testing';

export const closeHelp = `${CLOSE_USAGE}

--reason not-planned sets status/not-planned and closes the issue. --reason completed sets status/done and closes
an issue that records a current proof: a "Proven on" record of an account with write permission, written after the
issue's newest landing and after its last reopening. Without one it refuses and names issue-proof, which checks
the delivery and writes the proof. An issue that holds no "Landed on" record at all, and whose number no commit on the
default branch of origin of this clone names at the end of its subject, was delivered without a code change: a proof
written after its last reopening closes it, and the output says that no landing exists.`;

export const reopenHelp = `${REOPEN_USAGE}

Reopens each issue with an open status; if the first status label added after it by an account with write permission
is status/testing, earlier landings and releases still count. Every reopening requires a new proof; any other status
or no added status label also requires delivery again.`;

// An issue completes with a proof that follows its landing and its last reopening, which issue-proof writes.
// It says whether the issue holds no landing at all, so its close can say so: no "Landed on" record, and no commit of
// the default branch of origin that names it, which is work that landed without its record.
async function refuseWithoutCurrentProof(api: ForgejoClient, issue: Issue, context: CommandContext): Promise<boolean> {
  const name = formatIssue(issue.ref);
  if (issue.state !== 'open') throw new PreconditionError(`${name} is closed already`);
  const entries = await readTimeline(api, issue.ref);
  const history = await readIssueHistory(api, issue, entries);
  const deliveredWithoutCode = holdsNoLandedRecord(entries);
  if (findCurrentProof(history, deliveredWithoutCode) === undefined) {
    throw new PreconditionError(`${name} has no proof that follows its landing and its last reopening: a delivered issue is closed as completed by issue-proof, which records the proof; use --reason not-planned for work that is not done`);
  }
  const landedWithoutRecord = deliveredWithoutCode ? await findLandedCommitOf(context.git, context.cwd, issue.ref) : undefined;
  if (landedWithoutRecord !== undefined) {
    throw new PreconditionError(`${name} has no proof that follows its landing: the commit ${landedWithoutRecord.slice(0, 7)} on the default branch of origin names it, and the issue holds no "Landed on" record of that landing; run integrate-issue again, which writes it`);
  }
  return deliveredWithoutCode;
}

async function closeWithStatus(api: ForgejoClient, ref: IssueRef, issue: Issue, status: 'done' | 'not-planned'): Promise<void> {
  await replaceFamilyLabel(api, ref, issue, statusLabel(status));
  await afterStep(`close issue ${formatIssue(ref)}`, `set ${statusLabel(status)}`, () => editIssue(api, ref, { state: 'closed' }));
}

export async function runClose(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, { '--reason': 'value' });
  const { refs, rest } = await takeIssues(parsed.positionals, context.git, context.cwd, CLOSE_USAGE);
  refuseExtra(rest, CLOSE_USAGE);
  const reason = parsed.values.get('--reason') ?? 'completed';
  if (reason !== 'completed' && reason !== 'not-planned') throw new UsageError(`--reason must be completed or not-planned, not '${reason}'`);
  const api = context.api();
  const closed: string[] = [];
  if (reason === 'completed') {
    const issues = [];
    const withoutLanding = new Set<string>();
    for (const ref of refs) {
      const issue = await getIssue(api, ref);
      if (await refuseWithoutCurrentProof(api, issue, context)) withoutLanding.add(formatIssue(issue.ref));
      issues.push(issue);
    }
    await applyInOrder('close issues as completed', issues, (issue) => formatIssue(issue.ref), async (issue) => {
      await closeWithStatus(api, issue.ref, issue, 'done');
      closed.push(`${formatIssue(issue.ref)} closed as completed${withoutLanding.has(formatIssue(issue.ref)) ? '; no landing exists, it was delivered without a code change' : ''}`);
    });
    return succeeded(closed);
  }
  await applyInOrder(
    'close issues as not planned',
    refs,
    formatIssue,
    async (ref) => {
      await closeWithStatus(api, ref, await getIssue(api, ref), 'not-planned');
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
