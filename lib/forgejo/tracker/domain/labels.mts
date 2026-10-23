import { ContractError, NotFoundError, PartialCompletionError, expectNoBody, segment } from '../api/client.mts';
import type { ForgejoClient } from '../api/client.mts';
import { arrayOf, labelShape } from '../api/shapes.mts';
import type { CreateLabelBody, EditLabelBody, IssueLabelsBody, Label } from '../api/shapes.mts';
import { formatIssue, formatRepository, getIssue, issuePath, repositoryPath } from './issues.mts';
import type { Issue, IssueRef, RepositoryRef } from './issues.mts';
import { UsageError } from './refusals.mts';

export interface Family {
  readonly name: string;
  readonly exclusive: boolean;
}

// Forgejo scopes a label at its last slash, so a family label carries exactly one slash.
const FAMILIES: readonly Family[] = [
  { name: 'status', exclusive: true },
  { name: 'priority', exclusive: true },
  { name: 'type', exclusive: true },
  { name: 'goal', exclusive: true },
  { name: 'area', exclusive: false },
  { name: 'test', exclusive: true },
];

export const STATUS_VALUES = ['backlog', 'ready', 'planned', 'implementing', 'review', 'testing', 'done', 'not-planned'] as const;
export type StatusValue = (typeof STATUS_VALUES)[number];
export const OPEN_STATUS_VALUES: readonly StatusValue[] = ['backlog', 'ready', 'planned', 'implementing', 'review', 'testing'];
export const PRIORITY_VALUES = ['P0', 'P1', 'P2', 'P3', 'P9'] as const;
export type PriorityValue = (typeof PRIORITY_VALUES)[number];

export function familyOf(label: string): Family | undefined {
  const parts = label.split('/');
  if (parts.length !== 2 || parts[1] === '') return undefined;
  return FAMILIES.find((family) => family.name === parts[0]);
}

// labels.tsv names a label of a family `group:name`; Forgejo has it as `group/name`.
export function canonicalLabelName(name: string): string {
  const match = /^([a-z]+):(.+)$/.exec(name);
  if (match?.[1] === undefined || match[2] === undefined) return name;
  return FAMILIES.some((family) => family.name === match[1]) ? `${match[1]}/${match[2]}` : name;
}

export function statusLabel(value: StatusValue): string {
  return `status/${value}`;
}

export function priorityLabel(value: PriorityValue): string {
  return `priority/${value.toLowerCase()}`;
}

export function parseStatus(text: string): StatusValue {
  const found = STATUS_VALUES.find((value) => value === text);
  if (found === undefined) throw new UsageError(`the status must be one of ${STATUS_VALUES.join(', ')}, not '${text}'`);
  return found;
}

export function parsePriority(text: string): PriorityValue {
  const found = PRIORITY_VALUES.find((value) => value === text.toUpperCase());
  if (found === undefined) throw new UsageError(`the priority must be one of ${PRIORITY_VALUES.join(', ')}, not '${text}'`);
  return found;
}

// --- the catalog -----------------------------------------------------------------

export interface LabelDefinition {
  readonly name: string;
  readonly color: string;
  readonly description: string;
  readonly exclusive: boolean;
}

const CATALOG_GROUPS = ['type', 'area', 'closes', 'incident', 'needs', 'goal', 'test'];

// Reads the whole file before anything is written, so a bad row stops the run with nothing made.
export function parseCatalog(text: string, source: string): LabelDefinition[] {
  const definitions: LabelDefinition[] = [];
  const seen = new Set<string>();
  text.split('\n').forEach((line, index) => {
    if (line === '' || line.startsWith('#')) return;
    const where = `${source}:${index + 1}`;
    const columns = line.replace(/\r$/, '').split('\t');
    if (columns.length > 4) throw new UsageError(`${where} has more than four columns`);
    const [group = '', name = '', color = '', description = ''] = columns;
    if (!CATALOG_GROUPS.includes(group)) throw new UsageError(`${where} is in group '${group}', and there is only ${CATALOG_GROUPS.join(' ')}`);
    if (!name.startsWith(`${group}:`) || name.length === group.length + 1) throw new UsageError(`${where} is in group '${group}' but is named '${name}'`);
    if (!/^[0-9A-Fa-f]{6}$/.test(color)) throw new UsageError(`${where} has '${color}' where a six-digit hex color belongs`);
    if (description === '') throw new UsageError(`${where} has no description`);
    const canonical = canonicalLabelName(name);
    if (seen.has(canonical)) throw new UsageError(`${where} declares '${name}' a second time`);
    seen.add(canonical);
    definitions.push({ name: canonical, color: color.toLowerCase(), description, exclusive: familyOf(canonical)?.exclusive ?? false });
  });
  return definitions;
}

// The two families whose values are constants of the tracker, not rows of labels.tsv.
export function builtInLabels(): LabelDefinition[] {
  const status = STATUS_VALUES.map((value) => ({
    name: statusLabel(value),
    color: value === 'done' ? '0e8a16' : value === 'not-planned' ? 'cfd3d7' : 'c5def5',
    description: `The state of the work: ${value}`,
    exclusive: true,
  }));
  const colors: Record<PriorityValue, string> = { P0: 'b60205', P1: 'd93f0b', P2: 'fbca04', P3: '0e8a16', P9: 'cfd3d7' };
  const priority = PRIORITY_VALUES.map((value) => ({ name: priorityLabel(value), color: colors[value], description: `Priority ${value}`, exclusive: true }));
  return [...status, ...priority];
}

export interface SyncPlan {
  readonly create: readonly LabelDefinition[];
  readonly update: readonly { readonly id: number; readonly name: string; readonly changes: EditLabelBody }[];
  readonly unchanged: number;
  readonly leftAlone: readonly string[];
}

export function planSync(desired: readonly LabelDefinition[], existing: readonly Label[]): SyncPlan {
  const create: LabelDefinition[] = [];
  const update: { id: number; name: string; changes: EditLabelBody }[] = [];
  let unchanged = 0;
  for (const wanted of desired) {
    const found = existing.find((label) => label.name === wanted.name);
    if (found === undefined) {
      create.push(wanted);
      continue;
    }
    const changes: { color?: string; description?: string; exclusive?: boolean } = {};
    if (found.color.replace(/^#/, '').toLowerCase() !== wanted.color) changes.color = wanted.color;
    if ((found.description ?? '') !== wanted.description) changes.description = wanted.description;
    if ((found.exclusive ?? false) !== wanted.exclusive) changes.exclusive = wanted.exclusive;
    if (Object.keys(changes).length === 0) unchanged++;
    else update.push({ id: found.id, name: wanted.name, changes });
  }
  const known = new Set(desired.map((label) => label.name));
  return { create, update, unchanged, leftAlone: existing.filter((label) => !known.has(label.name)).map((label) => label.name) };
}

export async function listOrganizationLabels(api: ForgejoClient, organization: string): Promise<Label[]> {
  return api.callAll({ name: `list the labels of ${organization}`, path: `/orgs/${segment(organization)}/labels`, readItem: labelShape.type.read });
}

export async function applySync(api: ForgejoClient, organization: string, plan: SyncPlan): Promise<void> {
  const done: string[] = [];
  const fail = (name: string, error: unknown): never => {
    if (done.length === 0) throw error;
    throw new PartialCompletionError(`sync the labels of ${organization}`, done, `${name} failed: ${error instanceof Error ? error.message : String(error)}`);
  };
  for (const label of plan.create) {
    const body: CreateLabelBody = { name: label.name, color: label.color, description: label.description, exclusive: label.exclusive };
    try {
      await api.call({ name: `create the label ${label.name} of ${organization}`, method: 'POST', path: `/orgs/${segment(organization)}/labels`, body, success: 201, read: labelShape.type.read });
    } catch (error) {
      fail(label.name, error);
    }
    done.push(`created ${label.name}`);
  }
  for (const label of plan.update) {
    try {
      await api.call({ name: `update the label ${label.name} of ${organization}`, method: 'PATCH', path: `/orgs/${segment(organization)}/labels/${segment(label.id)}`, body: label.changes, success: 200, read: labelShape.type.read });
    } catch (error) {
      fail(label.name, error);
    }
    done.push(`updated ${label.name}`);
  }
}

// --- the labels of an issue -------------------------------------------------------

export interface LabelRequest {
  readonly add?: readonly string[];
  readonly remove?: readonly string[];
  readonly replace?: readonly string[];
}

export interface LabelPlan {
  readonly add: readonly string[];
  readonly remove: readonly string[];
}

// What to add and what to take off, so that only the families the request names change.
export function planLabelChange(current: readonly string[], request: LabelRequest): LabelPlan {
  const add = (request.add ?? []).map(canonicalLabelName);
  const remove = (request.remove ?? []).map(canonicalLabelName);
  const replace = (request.replace ?? []).map(canonicalLabelName);
  if (replace.length > 0 && (add.length > 0 || remove.length > 0)) throw new UsageError('--replace states the labels of a family, so it cannot be combined with --add or --remove');
  if (add.length + remove.length + replace.length === 0) throw new UsageError('name --add, --remove or --replace: a label change that changes nothing is a mistake');
  refuseSecondOfExclusiveFamily([...add, ...replace]);
  const overlap = add.find((name) => remove.includes(name));
  if (overlap !== undefined) throw new UsageError(`${overlap} is both added and removed`);

  const toAdd: string[] = [];
  const toRemove: string[] = [];
  for (const name of add) {
    if (current.includes(name) || toAdd.includes(name)) continue;
    const family = familyOf(name);
    const clash = family?.exclusive === true ? current.find((other) => familyOf(other)?.name === family.name) : undefined;
    if (clash !== undefined) throw new UsageError(`the issue has ${clash}, and ${name} is of the same exclusive family: use --replace to change it`);
    toAdd.push(name);
  }
  for (const name of remove) {
    if (current.includes(name) && !toRemove.includes(name)) toRemove.push(name);
  }
  for (const name of replace) {
    if (!current.includes(name) && !toAdd.includes(name)) toAdd.push(name);
    const family = familyOf(name);
    if (family === undefined) continue;
    for (const other of current) {
      if (familyOf(other)?.name === family.name && !replace.includes(other) && !toRemove.includes(other)) toRemove.push(other);
    }
  }
  return { add: toAdd, remove: toRemove };
}

function refuseSecondOfExclusiveFamily(names: readonly string[]): void {
  const seen = new Map<string, string>();
  for (const name of names) {
    const family = familyOf(name);
    if (family?.exclusive !== true) continue;
    const earlier = seen.get(family.name);
    if (earlier !== undefined && earlier !== name) throw new UsageError(`${earlier} and ${name} are of the exclusive family ${family.name}/, and an issue carries one`);
    seen.set(family.name, name);
  }
}

// The repository's labels as the issue form offers them: its own and, for an organization, the
// organization's. A list of the repository that already holds the organization's labels gives the
// same answer once, because the labels are told apart by their id.
export async function listVisibleLabels(api: ForgejoClient, repository: RepositoryRef): Promise<Label[]> {
  const name = `list the labels of ${formatRepository(repository)}`;
  const own = await api.callAll({ name, path: `${repositoryPath(repository)}/labels`, readItem: labelShape.type.read });
  const byId = new Map(own.map((label) => [label.id, label]));
  try {
    for (const label of await listOrganizationLabels(api, repository.owner)) byId.set(label.id, label);
  } catch (error) {
    if (!(error instanceof NotFoundError)) throw error;
  }
  return [...byId.values()];
}

export function resolveLabels(visible: readonly Label[], names: readonly string[], repository: RepositoryRef): Label[] {
  const unknown: string[] = [];
  const found: Label[] = [];
  for (const raw of names) {
    const name = canonicalLabelName(raw);
    const label = visible.find((candidate) => candidate.name === name);
    if (label === undefined) unknown.push(name);
    else if (!found.includes(label)) found.push(label);
  }
  if (unknown.length > 0) {
    throw new UsageError(`${formatRepository(repository)} has no label ${unknown.join(', ')}: add it to labels.tsv and run labels-sync --org ${repository.owner}`);
  }
  return found;
}

// A label change touches only what the plan names. It adds with POST and removes with DELETE and
// never replaces the whole set, because a replace removes every second label of an exclusive scope.
// The answer is read back, so a change Forgejo did not make is a contract failure.
export async function applyLabelChange(api: ForgejoClient, ref: IssueRef, issue: Issue, plan: LabelPlan): Promise<readonly string[]> {
  if (plan.add.length === 0 && plan.remove.length === 0) return issue.labels;
  const operation = `change the labels of issue ${formatIssue(ref)}`;
  const done: string[] = [];
  let ids = issue.labelIds;
  if (plan.add.length > 0) {
    const visible = await listVisibleLabels(api, ref);
    const labels = resolveLabels(visible, plan.add, ref);
    const body: IssueLabelsBody = { labels: labels.map((label) => label.id) };
    await api.call({ name: `add labels to issue ${formatIssue(ref)}`, method: 'POST', path: `${issuePath(ref)}/labels`, body, success: 200, read: arrayOf(labelShape.type).read });
    done.push(`added ${plan.add.join(', ')}`);
    if (plan.remove.length > 0) ids = (await getIssue(api, ref)).labelIds;
  }
  for (const name of plan.remove) {
    const id = ids[name];
    if (id === undefined) continue;
    try {
      await api.call({ name: `remove the label ${name} from issue ${formatIssue(ref)}`, method: 'DELETE', path: `${issuePath(ref)}/labels/${segment(id)}`, success: 204, read: expectNoBody });
    } catch (error) {
      if (done.length === 0) throw error;
      throw new PartialCompletionError(operation, done, `removing ${name} failed: ${error instanceof Error ? error.message : String(error)}`);
    }
    done.push(`removed ${name}`);
  }
  const after = (await getIssue(api, ref)).labels;
  const expected = [...issue.labels.filter((name) => !plan.remove.includes(name)), ...plan.add.filter((name) => !issue.labels.includes(name))];
  const actual = [...after].sort();
  if (actual.join('\n') !== [...expected].sort().join('\n')) {
    throw new ContractError(operation, `the labels are now ${actual.join(', ') || 'none'} and ${[...expected].sort().join(', ') || 'none'} were expected`);
  }
  return after;
}

// Sets the one label of a family an issue carries, and leaves every other label alone.
export async function replaceFamilyLabel(api: ForgejoClient, ref: IssueRef, issue: Issue, label: string): Promise<readonly string[]> {
  return applyLabelChange(api, ref, issue, planLabelChange(issue.labels, { replace: [label] }));
}
