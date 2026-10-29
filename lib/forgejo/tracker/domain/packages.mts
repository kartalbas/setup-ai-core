import { ContractError, NotFoundError, segment } from '../api/client.mts';
import type { ForgejoClient } from '../api/client.mts';
import { labelShape } from '../api/shapes.mts';
import type { CreateLabelBody, EditLabelBody, Label } from '../api/shapes.mts';
import { formatIssue, formatRepository, isSameIssue, isSameRepository } from './issues.mts';
import type { Issue, IssueRef, RepositoryRef } from './issues.mts';
import { listOrganizationLabels, listRepositoryLabels, statusLabel } from './labels.mts';
import { UsageError } from './refusals.mts';

const PACKAGE_COLOR = '5319e7';
const ANCHOR_PATTERN = /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[0-9]+/g;

export interface PackageRequest {
  readonly anchor: IssueRef;
  readonly members: readonly IssueRef[];
  readonly removals: readonly IssueRef[];
}

// The issues of one organization: its one package label is the label of all of them.
export interface PackageScope {
  readonly owner: string;
  readonly members: readonly IssueRef[];
  readonly removals: readonly IssueRef[];
}

export function packageLabelName(anchor: IssueRef): string {
  return `package/${anchor.repo}#${anchor.number}`;
}

export function packageLabelDescription(anchor: IssueRef): string {
  return `Package anchored at ${formatIssue(anchor)}`;
}

export function isPackageLabel(name: string): boolean {
  return name.startsWith('package/');
}

// The anchors a description names, each once, as it spells them.
export function anchorsNamedBy(description: string | undefined): string[] {
  const named = (description ?? '').match(ANCHOR_PATTERN) ?? [];
  return named.filter((anchor, index) => named.findIndex((other) => other.toLowerCase() === anchor.toLowerCase()) === index);
}

function refuseTwice(refs: readonly IssueRef[], option: string): void {
  refs.forEach((ref, index) => {
    if (refs.findIndex((other) => isSameIssue(other, ref)) !== index) throw new UsageError(`${formatIssue(ref)} is named twice with ${option}`);
  });
}

// Everything that can be refused without reading the tracker.
export function checkPackageRequest(request: PackageRequest): void {
  if (request.members.length + request.removals.length === 0) throw new UsageError('name the members of the package with --member, or the issues that left it with --remove: a package of nothing is a mistake');
  refuseTwice(request.members, '--member');
  refuseTwice(request.removals, '--remove');
  const both = request.members.find((member) => request.removals.some((removal) => isSameIssue(removal, member)));
  if (both !== undefined) throw new UsageError(`${formatIssue(both)} is both a member and a departure`);
}

export function groupByOwner(request: PackageRequest): PackageScope[] {
  const owners = new Map<string, string>();
  for (const ref of [...request.members, ...request.removals]) if (!owners.has(ref.owner.toLowerCase())) owners.set(ref.owner.toLowerCase(), ref.owner);
  return [...owners.entries()]
    .sort(([first], [second]) => first.localeCompare(second))
    .map(([key, owner]) => ({
      owner,
      members: request.members.filter((ref) => ref.owner.toLowerCase() === key),
      removals: request.removals.filter((ref) => ref.owner.toLowerCase() === key),
    }));
}

export function repositoriesOf(refs: readonly IssueRef[]): RepositoryRef[] {
  const found: RepositoryRef[] = [];
  for (const ref of refs) if (!found.some((other) => isSameRepository(other, ref))) found.push({ owner: ref.owner, repo: ref.repo });
  return found;
}

// A label of this name that names another anchor, or none, belongs to another package or to nobody: the name alone
// cannot tell the packages apart, because it leaves out the owner of the anchor.
function refuseForeignLabel(label: Label, anchor: IssueRef, owner: string): void {
  const named = anchorsNamedBy(label.description);
  if (named.length === 1 && named[0]?.toLowerCase() === formatIssue(anchor).toLowerCase()) return;
  const said = named.length === 0 ? 'names no anchor' : `names the anchor ${named.join(' and ')}`;
  throw new UsageError(`${owner} has the label ${label.name}, which ${said}, and this package is anchored at ${formatIssue(anchor)}: nothing was changed. Two packages cannot share a label name`);
}

export function isArchived(label: Label): boolean {
  if (label.is_archived === undefined) throw new ContractError(`read the label ${label.name}`, 'Forgejo did not say whether the label is archived');
  return label.is_archived;
}

// The one organization label of the package, or nothing. An organization that cannot list its labels has none to give.
export async function readPackageLabel(api: ForgejoClient, owner: string, anchor: IssueRef): Promise<Label | undefined> {
  let labels: Label[];
  try {
    labels = await listOrganizationLabels(api, owner);
  } catch (error) {
    if (error instanceof NotFoundError) throw new UsageError(`${owner} is no organization the token can read, and a package label is an organization label: ${error.message}`);
    throw error;
  }
  const name = packageLabelName(anchor);
  const found = labels.find((label) => label.name === name);
  if (found === undefined) return undefined;
  refuseForeignLabel(found, anchor, owner);
  isArchived(found);
  return found;
}

// The repository's own label of the name hides the organization's one: Forgejo removes a label from an issue by its name,
// and takes the repository's first.
export async function refuseRepositoryLabelOfPackageName(api: ForgejoClient, repository: RepositoryRef, anchor: IssueRef, organizationLabel: Label | undefined): Promise<void> {
  const name = packageLabelName(anchor);
  const own = (await listRepositoryLabels(api, repository)).find((label) => label.name === name && label.id !== organizationLabel?.id);
  if (own !== undefined) throw new UsageError(`${formatRepository(repository)} has its own label ${name}, which is no label of its organization: nothing was changed. Delete it or rename it first`);
}

export async function createPackageLabel(api: ForgejoClient, owner: string, anchor: IssueRef): Promise<Label> {
  const name = packageLabelName(anchor);
  const body: CreateLabelBody = { name, color: PACKAGE_COLOR, description: packageLabelDescription(anchor), exclusive: true };
  try {
    const created = await api.call({ name: `create the label ${name} of ${owner}`, method: 'POST', path: `/orgs/${segment(owner)}/labels`, body, success: 201, read: labelShape.type.read });
    isArchived(created);
    return created;
  } catch (error) {
    // Another run may have made it between the read and this write: only a fresh read of the label decides, never the status of the answer.
    const found = await readPackageLabel(api, owner, anchor);
    if (found === undefined) throw error;
    return found;
  }
}

async function editPackageLabel(api: ForgejoClient, owner: string, label: Label, body: EditLabelBody, operation: string): Promise<Label> {
  return api.call({ name: `${operation} the label ${label.name} of ${owner}`, method: 'PATCH', path: `/orgs/${segment(owner)}/labels/${segment(label.id)}`, body, success: 200, read: labelShape.type.read });
}

export async function makeLabelExclusive(api: ForgejoClient, owner: string, label: Label): Promise<Label> {
  const updated = await editPackageLabel(api, owner, label, { exclusive: true }, 'make exclusive');
  if (updated.exclusive !== true) throw new ContractError(`make exclusive the label ${label.name} of ${owner}`, 'Forgejo did not keep exclusive true');
  return updated;
}

export async function setLabelArchived(api: ForgejoClient, owner: string, label: Label, archived: boolean): Promise<Label> {
  const updated = await editPackageLabel(api, owner, label, { is_archived: archived }, archived ? 'archive' : 'reactivate');
  if (updated.is_archived !== archived) {
    throw new ContractError(`${archived ? 'archive' : 'reactivate'} the label ${label.name} of ${owner}`, `Forgejo answered is_archived ${String(updated.is_archived)} where ${String(archived)} was asked`);
  }
  return updated;
}

// Completed is what issue-proof and issue-close --reason completed leave: closed, and status/done.
export function isComplete(issue: Issue): boolean {
  return issue.state === 'closed' && issue.labels.includes(statusLabel('done'));
}

// A package with no member is not complete: nobody has shown that it is done.
export function isPackageComplete(members: readonly Issue[]): boolean {
  return members.length > 0 && members.every(isComplete);
}
