import type { ForgejoClient } from '../api/client.mts';
import { issueShape } from '../api/shapes.mts';
import type { IssueMetaBody } from '../api/shapes.mts';
import { ContractError } from '../api/client.mts';
import { formatIssue, isSameIssue, issuePath, parseRepository } from './issues.mts';
import type { IssueRef } from './issues.mts';
import { UsageError } from './refusals.mts';

// `blocked` depends on `blocker`: the request goes to the dependencies of the blocked issue and
// carries the blocker in its body. Both may live in any repository.

export async function listBlockers(api: ForgejoClient, blocked: IssueRef): Promise<IssueRef[]> {
  const name = `list what blocks issue ${formatIssue(blocked)}`;
  const issues = await api.callAll({ name, path: `${issuePath(blocked)}/dependencies`, readItem: issueShape.type.read });
  return issues.map((issue) => {
    const fullName = issue.repository?.full_name;
    if (fullName === undefined) throw new ContractError(name, `issue ${issue.number} names no repository`);
    return { ...parseRepository(fullName), number: issue.number };
  });
}

function meta(ref: IssueRef): IssueMetaBody {
  return { owner: ref.owner, repo: ref.repo, index: ref.number };
}

export async function addBlocker(api: ForgejoClient, blocked: IssueRef, blocker: IssueRef): Promise<void> {
  if (isSameIssue(blocked, blocker)) throw new UsageError(`${formatIssue(blocked)} cannot be blocked by itself`);
  const name = `block issue ${formatIssue(blocked)} by ${formatIssue(blocker)}`;
  await api.call({ name, method: 'POST', path: `${issuePath(blocked)}/dependencies`, body: meta(blocker), success: 201, read: issueShape.type.read });
  const blockers = await listBlockers(api, blocked);
  if (!blockers.some((known) => isSameIssue(known, blocker))) throw new ContractError(name, `${formatIssue(blocker)} is not among what blocks ${formatIssue(blocked)} afterwards`);
  if (blockers.some((known) => isSameIssue(known, blocked))) throw new ContractError(name, `${formatIssue(blocked)} blocks itself afterwards`);
}

// Whether a dependency was removed. A blocker that was not there is reported as nothing removed.
export async function removeBlocker(api: ForgejoClient, blocked: IssueRef, blocker: IssueRef): Promise<boolean> {
  const name = `unblock issue ${formatIssue(blocked)} from ${formatIssue(blocker)}`;
  if (!(await listBlockers(api, blocked)).some((known) => isSameIssue(known, blocker))) return false;
  await api.call({ name, method: 'DELETE', path: `${issuePath(blocked)}/dependencies`, body: meta(blocker), success: 200, read: issueShape.type.read });
  if ((await listBlockers(api, blocked)).some((known) => isSameIssue(known, blocker))) throw new ContractError(name, `${formatIssue(blocker)} still blocks ${formatIssue(blocked)} afterwards`);
  return true;
}
