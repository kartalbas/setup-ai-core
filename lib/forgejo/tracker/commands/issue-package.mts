import type { ForgejoClient } from '../api/client.mts';
import type { Label } from '../api/shapes.mts';
import { formatIssue, getIssue, parseIssueNumber, parseRepository } from '../domain/issues.mts';
import type { Issue, IssueRef } from '../domain/issues.mts';
import { applyLabelChange, planLabelChange } from '../domain/labels.mts';
import {
  checkPackageRequest,
  createPackageLabel,
  groupByOwner,
  isArchived,
  isComplete,
  isPackageComplete,
  isPackageLabel,
  makeLabelExclusive,
  packageLabelName,
  readPackageLabel,
  refuseRepositoryLabelOfPackageName,
  repositoriesOf,
  setLabelArchived,
} from '../domain/packages.mts';
import type { PackageRequest, PackageScope } from '../domain/packages.mts';
import { ContractError, PartialCompletionError, UsageError } from '../domain/refusals.mts';
import { listOf, parseArguments, parseIssueReference, refuseExtra } from './arguments.mts';
import { lines } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: issue-package OWNER/REPO NUMBER --member OWNER/REPO#NUMBER... [--remove OWNER/REPO#NUMBER...]';

export const help = `${USAGE}

Puts the label package/<repo>#<number> on every issue of a package, in every repository it spans, and takes it off
the issues that left. OWNER/REPO NUMBER is the first issue of the package, which stays its identity whoever joins or
leaves. --member names every issue of the package as it stands now, once each; --remove names the issues that were
members before and no longer are. The label is an exclusive label of each organization the members belong to, and its
description names the first issue as OWNER/REPO#NUMBER. Where an organization has a package/ label of that name that
names another first issue, or none, the command refuses before it writes anything.

Every issue named is read first, and nothing is written before all of them and every label are read. The result is
read back. When every member is closed with status/done, the label is archived: it stays on the issues and leaves the
label picker. When one is open, closed as not planned or without status/done, the label is active again. It never
closes or proves an issue, and a package with no member is never archived. Where a step fails, the answer names what was
confirmed and what is uncertain; run the same command again, it reads the tracker and finishes what is missing. Two
runs for one package at once are not serialized by the tracker: the coordinator runs one at a time.`;

function describeFailure(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function readIssues(api: ForgejoClient, refs: readonly IssueRef[]): Promise<Issue[]> {
  const issues: Issue[] = [];
  for (const ref of refs) issues.push(await getIssue(api, ref));
  return issues;
}

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, { '--member': 'repeat', '--remove': 'repeat' });
  const [repositoryText, numberText, ...extra] = parsed.positionals;
  if (repositoryText === undefined || numberText === undefined) throw new UsageError(USAGE);
  refuseExtra(extra, USAGE);
  const request: PackageRequest = {
    anchor: { ...parseRepository(repositoryText), number: parseIssueNumber(numberText) },
    members: listOf(parsed, '--member').map(parseIssueReference),
    removals: listOf(parsed, '--remove').map(parseIssueReference),
  };
  checkPackageRequest(request);
  return reconcile(context.api(), request);
}

async function reconcile(api: ForgejoClient, request: PackageRequest): Promise<CommandResult> {
  const { anchor, members, removals } = request;
  const name = packageLabelName(anchor);
  const operation = `reconcile the package ${name}`;
  const scopes = groupByOwner(request);

  // Nothing is written before every issue and every label of the request has been read.
  await getIssue(api, anchor);
  const readMembers = await readIssues(api, members);
  await readIssues(api, removals);
  const labels = new Map<string, Label | undefined>();
  for (const scope of scopes) {
    const label = await readPackageLabel(api, scope.owner, anchor);
    labels.set(scope.owner, label);
    for (const repository of repositoriesOf([...scope.members, ...scope.removals])) await refuseRepositoryLabelOfPackageName(api, repository, anchor, label);
  }

  const done: string[] = [];
  async function step<T>(what: string, action: () => Promise<T>): Promise<T> {
    try {
      const result = await action();
      done.push(what);
      return result;
    } catch (error) {
      if (done.length === 0) throw error;
      const completed = error instanceof PartialCompletionError ? [...done, ...error.completed] : done;
      throw new PartialCompletionError(operation, completed, `${what} failed: ${describeFailure(error)}. Run the same command again: it reads the tracker and finishes what is missing`);
    }
  }

  for (const scope of scopes) {
    const label = await prepareLabel(api, scope, anchor, labels.get(scope.owner), readMembers, step);
    if (label !== undefined) labels.set(scope.owner, label);
    for (const ref of scope.members) {
      const fresh = await getIssue(api, ref);
      const plan = planLabelChange(fresh.labels, { replace: [name] });
      if (plan.add.length + plan.remove.length > 0) await step(`labeled ${formatIssue(ref)}`, () => applyLabelChange(api, ref, fresh, plan));
    }
    for (const ref of scope.removals) {
      const fresh = await getIssue(api, ref);
      if (fresh.labels.includes(name)) await step(`took ${name} off ${formatIssue(ref)}`, () => applyLabelChange(api, ref, fresh, { add: [], remove: [name] }));
    }
  }

  const confirmed = await confirmMembership(api, request, scopes, name, step);
  const reportLines: string[] = [];
  for (const scope of scopes.filter((candidate) => candidate.members.length > 0)) {
    const complete = isPackageComplete(confirmed);
    const label = await readPackageLabel(api, scope.owner, anchor);
    if (label === undefined) throw new ContractError(operation, `${scope.owner} has no label ${name} after it was written`);
    const settled = isArchived(label) === complete ? label : await step(`${complete ? 'archived' : 'reactivated'} ${name} in ${scope.owner}`, () => setLabelArchived(api, scope.owner, label, complete));
    labels.set(scope.owner, settled);
    reportLines.push(`${scope.owner}: ${name} is ${complete ? 'archived' : 'active'}`);
  }
  await step('read every label and member back', () => confirmArchival(api, request, scopes, name, labels, confirmed));

  const completed = confirmed.filter(isComplete).length;
  return {
    stdout: lines(
      ...members.map((ref) => `${formatIssue(ref)} carries ${name}`),
      ...removals.map((ref) => `${formatIssue(ref)} does not carry ${name}`),
      ...reportLines,
      `${name}: ${members.length} members confirmed, ${removals.length} departures confirmed, ${completed} of ${members.length} members complete`,
    ),
    stderr: '',
    exitCode: 0,
  };
}

type Step = <T>(what: string, action: () => Promise<T>) => Promise<T>;

// The organization's label of the package, made ready for the members to be put on: it exists, is exclusive, and is not
// archived where an issue is about to get it, because an archived label cannot be put on an issue.
async function prepareLabel(api: ForgejoClient, scope: PackageScope, anchor: IssueRef, found: Label | undefined, readMembers: readonly Issue[], step: Step): Promise<Label | undefined> {
  if (scope.members.length === 0) return found;
  const name = packageLabelName(anchor);
  let label: Label = found ?? (await step(`created ${name} in ${scope.owner}`, () => createPackageLabel(api, scope.owner, anchor)));
  if (label.exclusive !== true) label = await step(`made ${name} exclusive in ${scope.owner}`, () => makeLabelExclusive(api, scope.owner, label));
  const lacking = readMembers.some((issue) => issue.ref.owner.toLowerCase() === scope.owner.toLowerCase() && !issue.labels.includes(name));
  if (lacking && isArchived(label)) label = await step(`reactivated ${name} in ${scope.owner}`, () => setLabelArchived(api, scope.owner, label, false));
  return label;
}

// Reads every member and every departure again, and the label of every organization with a member.
async function confirmMembership(api: ForgejoClient, request: PackageRequest, scopes: readonly PackageScope[], name: string, step: Step): Promise<Issue[]> {
  return step(`read back ${request.members.length} members and ${request.removals.length} departures`, async () => {
    const confirmed: Issue[] = [];
    for (const ref of request.members) {
      const issue = await getIssue(api, ref);
      const carried = issue.labels.filter(isPackageLabel);
      if (carried.length !== 1 || carried[0] !== name) throw new ContractError(`read back ${formatIssue(ref)}`, `it carries ${carried.join(', ') || 'no package label'} where only ${name} was expected`);
      confirmed.push(issue);
    }
    for (const ref of request.removals) {
      if ((await getIssue(api, ref)).labels.includes(name)) throw new ContractError(`read back ${formatIssue(ref)}`, `it still carries ${name}`);
    }
    for (const scope of scopes.filter((candidate) => candidate.members.length > 0)) {
      const label = await readPackageLabel(api, scope.owner, request.anchor);
      if (label?.exclusive !== true) throw new ContractError(`read back ${name}`, `${scope.owner} has no exclusive label of that name`);
    }
    return confirmed;
  });
}

// After the labels were archived or made active, each label is read once more and every member must still carry it.
async function confirmArchival(api: ForgejoClient, request: PackageRequest, scopes: readonly PackageScope[], name: string, labels: ReadonlyMap<string, Label | undefined>, confirmed: readonly Issue[]): Promise<void> {
  const complete = isPackageComplete(confirmed);
  for (const scope of scopes.filter((candidate) => candidate.members.length > 0)) {
    const label = await readPackageLabel(api, scope.owner, request.anchor);
    if (label === undefined || isArchived(label) !== complete) {
      throw new ContractError(`read back ${name}`, `${scope.owner} holds the label ${label === undefined ? 'nowhere' : isArchived(label) ? 'archived' : 'active'} where ${complete ? 'archived' : 'active'} was written`);
    }
    if (labels.get(scope.owner)?.id !== label.id) throw new ContractError(`read back ${name}`, `${scope.owner} answers another label than the one that was changed`);
  }
  for (const ref of request.members) {
    if (!(await getIssue(api, ref)).labels.includes(name)) throw new ContractError(`read back ${formatIssue(ref)}`, `it lost ${name}`);
  }
}
