import { formatIssue, parseIssueNumber, parseRepository } from '../domain/issues.mts';
import type { IssueRef } from '../domain/issues.mts';
import { addBlocker, removeBlocker } from '../domain/dependencies.mts';
import { UsageError } from '../domain/refusals.mts';
import { parseArguments } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const BLOCK_USAGE = 'usage: issue-block BLOCKED_OWNER/REPO NUMBER BY_OWNER/REPO NUMBER';
const UNBLOCK_USAGE = 'usage: issue-unblock BLOCKED_OWNER/REPO NUMBER BY_OWNER/REPO NUMBER';

export const blockHelp = `${BLOCK_USAGE}

Records that the first issue is blocked by the second, with Forgejo's own dependency relation. The blocked
issue comes first. Both may be in any repository.`;
export const unblockHelp = `${UNBLOCK_USAGE}

Removes the relation that the first issue is blocked by the second, and no other. A relation that does not
exist is reported and nothing is removed.`;

function parseAddresses(args: readonly string[], usage: string): { blocked: IssueRef; blocker: IssueRef } {
  const parsed = parseArguments(args, {});
  const [blockedRepository, blockedNumber, blockerRepository, blockerNumber, ...extra] = parsed.positionals;
  if (blockedRepository === undefined || blockedNumber === undefined || blockerRepository === undefined || blockerNumber === undefined || extra.length > 0) {
    throw new UsageError(usage);
  }
  return {
    blocked: { ...parseRepository(blockedRepository), number: parseIssueNumber(blockedNumber) },
    blocker: { ...parseRepository(blockerRepository), number: parseIssueNumber(blockerNumber) },
  };
}

export async function runBlock(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const { blocked, blocker } = parseAddresses(args, BLOCK_USAGE);
  await addBlocker(context.api(), blocked, blocker);
  return succeeded([`${formatIssue(blocked)} is blocked by ${formatIssue(blocker)}`]);
}

export async function runUnblock(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const { blocked, blocker } = parseAddresses(args, UNBLOCK_USAGE);
  const removed = await removeBlocker(context.api(), blocked, blocker);
  return succeeded([removed ? `${formatIssue(blocked)} is no longer blocked by ${formatIssue(blocker)}` : `${formatIssue(blocked)} was not blocked by ${formatIssue(blocker)}: nothing removed`]);
}
