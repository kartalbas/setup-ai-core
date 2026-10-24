import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import type { IncomingMessage, Server, ServerResponse } from 'node:http';
import type { AddressInfo } from 'node:net';
import { ForgejoClient } from '../api/client.mts';
import type { ClientOptions } from '../api/client.mts';
import { createTokenSource } from '../api/credentials.mts';
import type { CommandContext } from '../commands/command.mts';
import { GitClient } from '../git/git.mts';
import { createRecordingHarness } from './recording-harness.mts';

// A Forgejo that runs on this machine. It refuses what api/schema.json refuses: a path or a method
// the schema does not hold, a query parameter or a body field it does not name, a missing required
// field. It checks its own answers against the schema before it sends them, so a fault of the fake
// shows as a 500 that names it. The state behind the handlers is a small model of the issue tracker.

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
interface SchemaNode {
  type?: string;
  $ref?: string;
  properties?: Record<string, SchemaNode>;
  required?: string[];
  items?: SchemaNode;
  enum?: string[];
}
interface Parameter {
  name: string;
  in: string;
  required?: boolean;
  type?: string;
  schema?: SchemaNode;
}
interface OperationSchema {
  operationId: string;
  parameters?: Parameter[];
  responses: Record<string, { $ref?: string; schema?: SchemaNode }>;
}
interface SchemaFile {
  paths: Record<string, Record<string, OperationSchema>>;
  definitions: Record<string, SchemaNode>;
  responses: Record<string, { schema?: SchemaNode }>;
}

const schema = JSON.parse(readFileSync(new URL('../api/schema.json', import.meta.url), 'utf8')) as SchemaFile;

export const FAKE_TOKEN = 'fake-token-0123456789abcdef';
export const FAKE_HOST = 'forge.example.test';
const DEFAULT_PAGE_MAXIMUM = 50;

interface FakeLabel {
  id: number;
  name: string;
  color: string;
  description: string;
  exclusive: boolean;
  owner: string;
  repo: string | undefined;
}
interface FakeComment {
  id: number;
  login: string;
  body: string;
  created_at: string;
}
interface Reference {
  owner: string;
  repo: string;
  index: number;
}
interface FakeEvent {
  id: number;
  type: 'close' | 'reopen' | 'milestone';
  login: string;
  created_at: string;
  milestone: FakeMilestone | undefined;
}
interface FakeMilestone {
  id: number;
  title: string;
}
interface FakeIssue {
  id: number;
  number: number;
  title: string;
  body: string;
  state: 'open' | 'closed';
  labels: number[];
  assignees: string[];
  comments: FakeComment[];
  events: FakeEvent[];
  milestone: FakeMilestone | undefined;
  dependencies: Reference[];
  created_at: string;
}
interface FakeRepository {
  owner: string;
  name: string;
  isPrivate: boolean;
  defaultBranch: string;
  assignable: string[];
  issues: FakeIssue[];
  tags: string[];
  milestones: FakeMilestone[];
  permissions: Record<string, string>;
  checks: string[];
}

export type FailureMode =
  | { kind: 'status'; status: number; message: string }
  | { kind: 'drop-before' }
  | { kind: 'drop-after' }
  | { kind: 'stall' }
  | { kind: 'malformed' }
  | { kind: 'success-status'; status: number }
  | { kind: 'omit-field'; field: string }
  | { kind: 'truncate-list' }
  | { kind: 'insert-null'; at: number };

export interface FailureRule {
  method?: string;
  path: string | RegExp;
  mode: FailureMode;
  times?: number;
}

export interface RecordedRequest {
  method: string;
  path: string;
  query: Record<string, string>;
  body: unknown;
}

export interface FakeOptions {
  pageMaximum?: number;
  userScopeMissing?: boolean;
}

export interface FakeForgejo {
  readonly url: string;
  readonly token: string;
  readonly requests: RecordedRequest[];
  addRepository(fullName: string, options?: { isPrivate?: boolean; assignable?: string[]; defaultBranch?: string }): void;
  addTag(fullName: string, tag: string): void;
  // The permission the repository gives an account: none, read, write, admin or owner. An account no one ever named answers 404.
  setPermission(fullName: string, login: string, permission: string): void;
  // The states the combined status of any commit of the repository answers one after the other, the last one for good. No state: an empty answer.
  setChecks(fullName: string, states: string[]): void;
  listMilestones(fullName: string): { title: string; issues: number[] }[];
  addLabel(owner: string, label: { name: string; color?: string; description?: string; exclusive?: boolean }): number;
  addIssue(fullName: string, issue: { title: string; body?: string; state?: 'open' | 'closed'; labels?: string[]; assignees?: string[] }): number;
  addComment(fullName: string, number: number, login: string, body: string): void;
  readIssue(fullName: string, number: number): { title: string; body: string; state: string; labels: string[]; assignees: string[]; comments: string[]; dependencies: string[]; milestone: string | undefined };
  listLabels(owner: string): { name: string; color: string; description: string; exclusive: boolean }[];
  fail(rule: FailureRule): void;
  writes(): RecordedRequest[];
  close(): Promise<void>;
}

class HttpFailure extends Error {
  readonly status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

interface Answer {
  status: number;
  body: Json | undefined;
  headers?: Record<string, string>;
}

export async function startFakeForgejo(options: FakeOptions = {}): Promise<FakeForgejo> {
  const repositories = new Map<string, FakeRepository>();
  const organizations = new Set<string>();
  const labels: FakeLabel[] = [];
  const knownLogins = new Set<string>(['fake-user']);
  const rules: (FailureRule & { left: number })[] = [];
  const requests: RecordedRequest[] = [];
  const pageMaximum = options.pageMaximum ?? DEFAULT_PAGE_MAXIMUM;
  let nextId = 1000;
  const newId = (): number => nextId++;
  const clock = (): string => new Date(Date.UTC(2026, 0, 1, 0, 0, nextId)).toISOString();

  const findRepository = (owner: string, repo: string): FakeRepository => {
    const found = repositories.get(`${owner}/${repo}`.toLowerCase());
    if (found === undefined) throw new HttpFailure(404, `repository does not exist [owner: ${owner}, name: ${repo}]`);
    return found;
  };
  const findIssue = (repository: FakeRepository, index: number): FakeIssue => {
    const found = repository.issues.find((issue) => issue.number === index);
    if (found === undefined) throw new HttpFailure(404, `issue does not exist [index: ${index}]`);
    return found;
  };
  const visibleLabels = (repository: FakeRepository): FakeLabel[] =>
    labels.filter((label) => (label.repo === undefined && label.owner === repository.owner && organizations.has(label.owner)) || (label.repo === repository.name && label.owner === repository.owner));
  const scopeOf = (name: string): string | undefined => (name.includes('/') ? name.slice(0, name.lastIndexOf('/')) : undefined);

  const userWire = (login: string): Json => ({ login, id: login.length, full_name: '', email: '', avatar_url: '' });
  const labelWire = (label: FakeLabel): Json => ({
    id: label.id,
    name: label.name,
    color: label.color,
    description: label.description,
    exclusive: label.exclusive,
    is_archived: false,
    url: `https://${FAKE_HOST}/api/v1/labels/${label.id}`,
  });
  const issueWire = (repository: FakeRepository, issue: FakeIssue): Json => ({
    id: issue.id,
    number: issue.number,
    title: issue.title,
    body: issue.body,
    state: issue.state,
    labels: labels.filter((label) => issue.labels.includes(label.id)).map(labelWire),
    assignees: issue.assignees.length === 0 ? null : issue.assignees.map(userWire),
    comments: issue.comments.length,
    created_at: issue.created_at,
    updated_at: issue.created_at,
    html_url: `https://${FAKE_HOST}/${repository.owner}/${repository.name}/issues/${issue.number}`,
    url: `https://${FAKE_HOST}/api/v1/repos/${repository.owner}/${repository.name}/issues/${issue.number}`,
    user: userWire('author'),
    repository: { id: 1, name: repository.name, owner: repository.owner, full_name: `${repository.owner}/${repository.name}` },
    milestone: issue.milestone === undefined ? null : milestoneWire(issue.milestone),
  });
  const milestoneWire = (milestone: FakeMilestone): Json => ({ id: milestone.id, title: milestone.title, description: '', state: 'open', open_issues: 0, closed_issues: 0 });
  const eventOf = (issue: FakeIssue, type: FakeEvent['type'], milestone?: FakeMilestone): void => {
    issue.events.push({ id: newId(), type, login: 'fake-user', created_at: clock(), milestone });
  };

  // X-Total-Count as Forgejo v17.0.0 sends it: the length of the list for most lists, the length of the page for
  // the timeline (routers/api/v1/repo/issue_comment.go), and none for the dependencies (issue_dependency.go).
  const paginate = (items: Json[], operation: OperationSchema, query: Record<string, string>, count: 'list' | 'page' | 'none' = 'list'): Answer => {
    const paged = (operation.parameters ?? []).some((parameter) => parameter.name === 'page');
    if (!paged) return { status: 200, body: items };
    const page = Math.max(1, Number(query.page ?? '1'));
    const limit = Math.min(Number(query.limit ?? String(pageMaximum)), pageMaximum);
    const body = items.slice((page - 1) * limit, page * limit);
    if (count === 'none') return { status: 200, body };
    // an empty page of the timeline is a Go nil slice, which Forgejo v17.0.0 writes as null
    return { status: 200, body: count === 'page' && body.length === 0 ? null : body, headers: { 'X-Total-Count': String(count === 'list' ? items.length : body.length) } };
  };

  const addLabelToIssue = (issue: FakeIssue, label: FakeLabel): void => {
    if (issue.labels.includes(label.id)) return;
    const scope = scopeOf(label.name);
    if (label.exclusive && scope !== undefined) {
      issue.labels = issue.labels.filter((id) => labels.find((other) => other.id === id && scopeOf(other.name) === scope) === undefined);
    }
    issue.labels.push(label.id);
  };

  type Handler = (context: { params: Record<string, string>; query: Record<string, string>; body: Record<string, unknown>; operation: OperationSchema }) => Answer;
  const handlers: Record<string, Handler> = {
    userGetCurrent: () => {
      if (options.userScopeMissing === true) throw new HttpFailure(403, 'token does not have at least one of required scope(s): read:user');
      return { status: 200, body: userWire('fake-user') };
    },
    repoGet: ({ params }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      return {
        status: 200,
        body: { id: 1, name: repository.name, full_name: `${repository.owner}/${repository.name}`, private: repository.isPrivate, default_branch: repository.defaultBranch, owner: userWire(repository.owner) },
      };
    },
    issueCreateIssue: ({ params, body }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      const issue: FakeIssue = {
        id: newId(),
        number: repository.issues.length + 1,
        title: String(body.title),
        body: typeof body.body === 'string' ? body.body : '',
        state: body.closed === true ? 'closed' : 'open',
        labels: [],
        assignees: [],
        comments: [],
        events: [],
        milestone: undefined,
        dependencies: [],
        created_at: clock(),
      };
      const available = visibleLabels(repository);
      for (const id of (body.labels as number[] | undefined) ?? []) {
        const label = available.find((candidate) => candidate.id === id);
        if (label === undefined) throw new HttpFailure(422, `label does not exist [id: ${id}]`);
        addLabelToIssue(issue, label);
      }
      for (const login of (body.assignees as string[] | undefined) ?? []) {
        if (!repository.assignable.includes(login)) throw new HttpFailure(422, `user does not exist [name: ${login}]`);
        issue.assignees.push(login);
      }
      repository.issues.push(issue);
      return { status: 201, body: issueWire(repository, issue) };
    },
    issueGetIssue: ({ params }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      return { status: 200, body: issueWire(repository, findIssue(repository, Number(params.index))) };
    },
    issueEditIssue: ({ params, body }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      const issue = findIssue(repository, Number(params.index));
      if (typeof body.title === 'string') issue.title = body.title;
      if (typeof body.body === 'string') issue.body = body.body;
      if (typeof body.state === 'string') {
        if (body.state !== 'open' && body.state !== 'closed') throw new HttpFailure(422, 'state must be open or closed');
        if (body.state !== issue.state) eventOf(issue, body.state === 'closed' ? 'close' : 'reopen');
        issue.state = body.state;
      }
      if (typeof body.milestone === 'number') {
        const milestone = body.milestone === 0 ? undefined : repository.milestones.find((candidate) => candidate.id === body.milestone);
        if (body.milestone !== 0 && milestone === undefined) throw new HttpFailure(422, `milestone does not exist [id: ${body.milestone}]`);
        if (milestone?.id !== issue.milestone?.id) eventOf(issue, 'milestone', milestone);
        issue.milestone = milestone;
      }
      if (Array.isArray(body.assignees)) {
        for (const login of body.assignees as string[]) {
          if (!repository.assignable.includes(login)) throw new HttpFailure(422, `user does not exist [name: ${login}]`);
        }
        issue.assignees = [...(body.assignees as string[])];
      }
      return { status: 201, body: issueWire(repository, issue) };
    },
    issueGetComments: ({ params }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      const issue = findIssue(repository, Number(params.index));
      return {
        status: 200,
        body: issue.comments.map((comment) => ({ id: comment.id, html_url: `https://${FAKE_HOST}/comment/${comment.id}`, body: comment.body, created_at: comment.created_at, updated_at: comment.created_at, user: userWire(comment.login) })),
      };
    },
    issueCreateComment: ({ params, body }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      const issue = findIssue(repository, Number(params.index));
      const comment: FakeComment = { id: newId(), login: 'fake-user', body: String(body.body), created_at: clock() };
      issue.comments.push(comment);
      return { status: 201, body: { id: comment.id, html_url: `https://${FAKE_HOST}/comment/${comment.id}`, body: comment.body, created_at: comment.created_at, updated_at: comment.created_at, user: userWire(comment.login) } };
    },
    repoGetAssignees: ({ params }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      return { status: 200, body: repository.assignable.map(userWire) };
    },
    issueListIssueDependencies: ({ params, operation, query }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      const issue = findIssue(repository, Number(params.index));
      const blockers = issue.dependencies.map((reference) => {
        const other = findRepository(reference.owner, reference.repo);
        return issueWire(other, findIssue(other, reference.index));
      });
      return paginate(blockers, operation, query, 'none');
    },
    issueCreateIssueDependencies: ({ params, body }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      const issue = findIssue(repository, Number(params.index));
      const reference: Reference = { owner: String(body.owner), repo: String(body.repo), index: Number(body.index) };
      const other = findRepository(reference.owner, reference.repo);
      const blocker = findIssue(other, reference.index);
      if (other === repository && blocker === issue) throw new HttpFailure(400, 'an issue cannot depend on itself');
      if (!issue.dependencies.some((known) => known.owner === other.owner && known.repo === other.name && known.index === blocker.number)) {
        issue.dependencies.push({ owner: other.owner, repo: other.name, index: blocker.number });
      }
      return { status: 201, body: issueWire(repository, issue) };
    },
    issueRemoveIssueDependencies: ({ params, body }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      const issue = findIssue(repository, Number(params.index));
      findIssue(findRepository(String(body.owner), String(body.repo)), Number(body.index));
      issue.dependencies = issue.dependencies.filter(
        (known) => !(known.owner.toLowerCase() === String(body.owner).toLowerCase() && known.repo.toLowerCase() === String(body.repo).toLowerCase() && known.index === Number(body.index)),
      );
      return { status: 200, body: issueWire(repository, issue) };
    },
    issueAddLabel: ({ params, body }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      const issue = findIssue(repository, Number(params.index));
      const available = visibleLabels(repository);
      const requested = (body.labels as (number | string)[]).map((entry) => {
        const label = available.find((candidate) => (typeof entry === 'number' ? candidate.id === entry : candidate.name === entry));
        if (label === undefined) throw new HttpFailure(422, `label does not exist [${String(entry)}]`);
        return label;
      });
      for (const label of requested) addLabelToIssue(issue, label);
      return { status: 200, body: labels.filter((label) => issue.labels.includes(label.id)).map(labelWire) };
    },
    issueRemoveLabel: ({ params }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      const issue = findIssue(repository, Number(params.index));
      const identifier = params.identifier ?? '';
      const label = visibleLabels(repository).find((candidate) => String(candidate.id) === identifier || candidate.name === identifier);
      if (label === undefined) throw new HttpFailure(404, `label does not exist [${identifier}]`);
      issue.labels = issue.labels.filter((id) => id !== label.id);
      return { status: 204, body: undefined };
    },
    issueListLabels: ({ params, operation, query }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      return paginate(visibleLabels(repository).map(labelWire), operation, query);
    },
    orgListLabels: ({ params, operation, query }) => {
      const org = params.org ?? '';
      if (!organizations.has(org)) throw new HttpFailure(404, `organization does not exist [name: ${org}]`);
      return paginate(labels.filter((label) => label.owner === org && label.repo === undefined).map(labelWire), operation, query);
    },
    orgCreateLabel: ({ params, body }) => {
      const org = params.org ?? '';
      if (!organizations.has(org)) throw new HttpFailure(404, `organization does not exist [name: ${org}]`);
      const color = String(body.color);
      if (!/^#?[0-9a-fA-F]{6}$/.test(color)) throw new HttpFailure(422, 'color must be six hexadecimal digits');
      if (labels.some((label) => label.owner === org && label.repo === undefined && label.name === body.name)) throw new HttpFailure(422, 'label already exists');
      const label: FakeLabel = {
        id: newId(),
        name: String(body.name),
        color: color.replace(/^#/, '').toLowerCase(),
        description: typeof body.description === 'string' ? body.description : '',
        exclusive: body.exclusive === true,
        owner: org,
        repo: undefined,
      };
      labels.push(label);
      return { status: 201, body: labelWire(label) };
    },
    orgEditLabel: ({ params, body }) => {
      const org = params.org ?? '';
      const label = labels.find((candidate) => candidate.owner === org && candidate.repo === undefined && String(candidate.id) === params.id);
      if (label === undefined) throw new HttpFailure(404, `label does not exist [id: ${params.id}]`);
      if (typeof body.name === 'string') label.name = body.name;
      if (typeof body.color === 'string') label.color = body.color.replace(/^#/, '').toLowerCase();
      if (typeof body.description === 'string') label.description = body.description;
      if (typeof body.exclusive === 'boolean') label.exclusive = body.exclusive;
      return { status: 200, body: labelWire(label) };
    },
    repoGetTag: ({ params }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      const tag = params.tag ?? '';
      if (!repository.tags.includes(tag)) throw new HttpFailure(404, `tag does not exist [name: ${tag}]`);
      return { status: 200, body: { name: tag, id: 'f'.repeat(40), message: '' } };
    },
    issueGetMilestonesList: ({ params, operation, query }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      return paginate(repository.milestones.filter((milestone) => query.name === undefined || milestone.title === query.name).map(milestoneWire), operation, query);
    },
    issueCreateMilestone: ({ params, body }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      const milestone: FakeMilestone = { id: newId(), title: String(body.title) };
      repository.milestones.push(milestone);
      return { status: 201, body: milestoneWire(milestone) };
    },
    issueGetCommentsAndTimeline: ({ params, operation, query }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      const issue = findIssue(repository, Number(params.index));
      const entries: { id: number; wire: Json }[] = [
        ...issue.comments.map((comment) => ({
          id: comment.id,
          wire: { id: comment.id, type: 'comment', body: comment.body, created_at: comment.created_at, updated_at: comment.created_at, html_url: `https://${FAKE_HOST}/comment/${comment.id}`, user: userWire(comment.login) },
        })),
        ...issue.events.map((event) => ({
          id: event.id,
          wire: {
            id: event.id,
            type: event.type,
            body: '',
            created_at: event.created_at,
            updated_at: event.created_at,
            user: userWire(event.login),
            ...(event.milestone === undefined ? {} : { milestone: milestoneWire(event.milestone) }),
          },
        })),
      ];
      return paginate(entries.sort((a, b) => a.id - b.id).map((entry) => entry.wire), operation, query, 'page');
    },
    repoGetRepoPermissions: ({ params }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      const login = params.collaborator ?? '';
      const permission = repository.permissions[login] ?? (knownLogins.has(login) ? 'read' : undefined);
      if (permission === undefined) throw new HttpFailure(404, `user does not exist [name: ${login}]`);
      return { status: 200, body: { permission, role_name: permission, user: userWire(login) } };
    },
    repoGetCombinedStatusByRef: ({ params }) => {
      const repository = findRepository(params.owner ?? '', params.repo ?? '');
      const state = repository.checks.length > 1 ? repository.checks.shift() : repository.checks[0];
      const body: Json = state === undefined ? {} : { state, total_count: 1, sha: params.ref ?? '', statuses: [] };
      return { status: 200, body };
    },
    issueSearchIssues: ({ query, operation }) => {
      const state = query.state ?? 'open';
      const wanted = (query.labels ?? '').split(',').filter((name) => name !== '');
      const known = wanted.filter((name) => labels.some((label) => label.name === name));
      const found: { repository: FakeRepository; issue: FakeIssue }[] = [];
      if ((query.type ?? 'issues') === 'issues') {
        for (const repository of repositories.values()) {
          if (query.owner !== undefined && repository.owner !== query.owner) continue;
          for (const issue of repository.issues) {
            if (state !== 'all' && issue.state !== state) continue;
            if (known.length > 0 && !issue.labels.some((id) => known.includes(labels.find((label) => label.id === id)?.name ?? ''))) continue;
            found.push({ repository, issue });
          }
        }
      }
      found.sort((a, b) => b.issue.created_at.localeCompare(a.issue.created_at) || b.issue.number - a.issue.number);
      return paginate(found.map((entry) => issueWire(entry.repository, entry.issue)), operation, query);
    },
  };

  // --- the schema checks -------------------------------------------------------

  const resolve = (node: SchemaNode): SchemaNode => {
    if (node.$ref === undefined) return node;
    const target = schema.definitions[node.$ref.replace('#/definitions/', '')];
    if (target === undefined) throw new Error(`api/schema.json has no definition for ${node.$ref}`);
    return target;
  };
  const validate = (value: unknown, node: SchemaNode, where: string, problems: string[], isResponse: boolean): void => {
    const resolved = resolve(node);
    if (value === null && isResponse && (resolved.type === 'array' || resolved.type === 'object' || resolved.properties !== undefined)) return;
    if (resolved.type === 'string') {
      if (typeof value !== 'string') problems.push(`${where} must be a string`);
      else if (resolved.enum !== undefined && !resolved.enum.includes(value)) problems.push(`${where} must be one of ${resolved.enum.join(', ')}`);
    } else if (resolved.type === 'integer') {
      if (typeof value !== 'number' || !Number.isInteger(value)) problems.push(`${where} must be an integer`);
    } else if (resolved.type === 'boolean') {
      if (typeof value !== 'boolean') problems.push(`${where} must be a boolean`);
    } else if (resolved.type === 'array') {
      if (!Array.isArray(value)) problems.push(`${where} must be a list`);
      else if (resolved.items !== undefined && Object.keys(resolved.items).length > 0) value.forEach((entry: unknown, index: number) => validate(entry, resolved.items as SchemaNode, `${where}[${index}]`, problems, isResponse));
    } else if (resolved.type === 'object' || resolved.properties !== undefined) {
      if (typeof value !== 'object' || value === null || Array.isArray(value)) {
        problems.push(`${where} must be an object`);
        return;
      }
      const record = value as Record<string, unknown>;
      for (const name of resolved.required ?? []) {
        if (record[name] === undefined) problems.push(`${where}.${name} is required`);
      }
      for (const [name, entry] of Object.entries(record)) {
        const property = resolved.properties?.[name];
        if (property === undefined) problems.push(`${where}.${name} is not a field of the definition`);
        else validate(entry, property, `${where}.${name}`, problems, isResponse);
      }
    }
  };

  const route = (path: string): { template: string; params: Record<string, string> } | undefined => {
    const parts = path.split('/').filter((part) => part !== '');
    let best: { template: string; params: Record<string, string>; literals: number } | undefined;
    for (const template of Object.keys(schema.paths)) {
      const expected = template.split('/').filter((part) => part !== '');
      if (expected.length !== parts.length) continue;
      const params: Record<string, string> = {};
      let literals = 0;
      let matches = true;
      expected.forEach((part, index) => {
        const actual = parts[index] ?? '';
        if (part.startsWith('{')) params[part.slice(1, -1)] = decodeURIComponent(actual);
        else if (part === actual) literals++;
        else matches = false;
      });
      if (matches && (best === undefined || literals > best.literals)) best = { template, params, literals };
    }
    return best;
  };

  const answerRequest = (method: string, path: string, query: Record<string, string>, rawBody: string): Answer => {
    const found = route(path);
    if (found === undefined) throw new HttpFailure(404, `${path} is not a path of api/schema.json`);
    const operation = schema.paths[found.template]?.[method.toLowerCase()];
    if (operation === undefined) throw new HttpFailure(405, `${method} ${found.template} is not in api/schema.json`);
    const problems: string[] = [];
    const declared = operation.parameters ?? [];
    for (const parameter of declared) {
      if (parameter.in === 'path' && parameter.type === 'integer' && !/^[0-9]+$/.test(found.params[parameter.name] ?? '')) problems.push(`${parameter.name} must be an integer`);
      if (parameter.in === 'query' && parameter.required === true && query[parameter.name] === undefined) problems.push(`query ${parameter.name} is required`);
    }
    for (const name of Object.keys(query)) {
      if (!declared.some((parameter) => parameter.in === 'query' && parameter.name === name)) problems.push(`query ${name} is not a parameter of ${operation.operationId}`);
    }
    let body: Record<string, unknown> = {};
    const bodyParameter = declared.find((parameter) => parameter.in === 'body');
    if (bodyParameter?.schema !== undefined) {
      let parsed: unknown;
      try {
        parsed = rawBody === '' ? {} : JSON.parse(rawBody);
      } catch {
        throw new HttpFailure(422, 'the body is not JSON');
      }
      validate(parsed, bodyParameter.schema, 'body', problems, false);
      body = parsed as Record<string, unknown>;
    }
    if (problems.length > 0) throw new HttpFailure(422, problems.join('; '));
    const handler = handlers[operation.operationId];
    if (handler === undefined) throw new HttpFailure(501, `the fake has no handler for ${operation.operationId}`);
    const answer = handler({ params: found.params, query, body, operation });
    const documented = operation.responses[String(answer.status)];
    if (documented === undefined) throw new HttpFailure(500, `FAKE BUG: ${operation.operationId} may not answer ${answer.status}`);
    const reference = documented.$ref?.replace('#/responses/', '');
    const responseSchema = documented.schema ?? (reference === undefined ? undefined : schema.responses[reference]?.schema);
    if (answer.body !== undefined && responseSchema !== undefined) {
      const checks: string[] = [];
      validate(answer.body, responseSchema, 'response', checks, true);
      if (checks.length > 0) throw new HttpFailure(500, `FAKE BUG: ${operation.operationId} answers outside the schema: ${checks.join('; ')}`);
    }
    return answer;
  };

  // --- the server --------------------------------------------------------------

  const omit = (value: Json | undefined, field: string): Json | undefined => {
    if (Array.isArray(value)) return value.map((entry) => omit(entry, field) as Json);
    if (typeof value === 'object' && value !== null) {
      const copy: { [key: string]: Json } = { ...value };
      delete copy[field];
      return copy;
    }
    return value;
  };

  const server: Server = createServer((request: IncomingMessage, response: ServerResponse) => {
    const chunks: Buffer[] = [];
    request.on('data', (chunk: Buffer) => chunks.push(chunk));
    request.on('end', () => {
      const url = new URL(request.url ?? '/', 'http://localhost');
      const method = request.method ?? 'GET';
      const path = url.pathname.replace(/^\/api\/v1/, '');
      const query: Record<string, string> = {};
      url.searchParams.forEach((value, key) => {
        query[key] = value;
      });
      const rawBody = Buffer.concat(chunks).toString('utf8');
      let recordedBody: unknown;
      try {
        recordedBody = rawBody === '' ? undefined : JSON.parse(rawBody);
      } catch {
        recordedBody = rawBody;
      }
      requests.push({ method, path, query, body: recordedBody });

      const send = (status: number, body: Json | undefined, headers: Record<string, string> = {}): void => {
        const text = body === undefined ? '' : JSON.stringify(body);
        response.writeHead(status, { 'Content-Type': 'application/json;charset=utf-8', ...headers });
        response.end(text);
      };
      const rule = rules.find((candidate) => candidate.left > 0 && (candidate.method === undefined || candidate.method === method) && (typeof candidate.path === 'string' ? candidate.path === path : candidate.path.test(path)));
      if (rule !== undefined) rule.left--;
      const mode = rule?.mode;

      if (request.headers.authorization !== `token ${FAKE_TOKEN}`) {
        send(401, { message: 'token is required' });
        return;
      }
      if (mode?.kind === 'status') {
        send(mode.status, { message: mode.message });
        return;
      }
      if (mode?.kind === 'drop-before') {
        request.socket.destroy();
        return;
      }
      if (mode?.kind === 'stall') return;
      let answer: Answer;
      try {
        answer = answerRequest(method, path, query, rawBody);
      } catch (error) {
        if (error instanceof HttpFailure) send(error.status, { message: error.message });
        else send(500, { message: `FAKE BUG: ${String(error)}` });
        return;
      }
      if (mode?.kind === 'drop-after') {
        request.socket.destroy();
        return;
      }
      if (mode?.kind === 'malformed') {
        response.writeHead(answer.status, { 'Content-Type': 'application/json' });
        response.end('{"number": ');
        return;
      }
      const status = mode?.kind === 'success-status' ? mode.status : answer.status;
      let body = mode?.kind === 'omit-field' ? omit(answer.body, mode.field) : answer.body;
      if (mode?.kind === 'truncate-list' && Array.isArray(body)) body = body.slice(0, -1);
      if (mode?.kind === 'insert-null' && Array.isArray(body)) body = [...body.slice(0, mode.at), null, ...body.slice(mode.at)];
      send(status, body, answer.headers);
    });
  });

  await new Promise<void>((resolveListening) => server.listen(0, '127.0.0.1', resolveListening));
  const { port } = server.address() as AddressInfo;

  const labelByName = (owner: string, name: string): FakeLabel => {
    const found = labels.find((label) => label.owner === owner && label.name === name);
    if (found === undefined) throw new Error(`the fake has no label ${name} of ${owner}`);
    return found;
  };

  return {
    url: `http://127.0.0.1:${port}`,
    token: FAKE_TOKEN,
    requests,
    addRepository(fullName, repositoryOptions = {}) {
      const [owner = '', name = ''] = fullName.split('/');
      organizations.add(owner);
      repositories.set(fullName.toLowerCase(), {
        owner,
        name,
        isPrivate: repositoryOptions.isPrivate ?? false,
        defaultBranch: repositoryOptions.defaultBranch ?? 'master',
        assignable: repositoryOptions.assignable ?? ['fake-user'],
        issues: [],
        tags: [],
        milestones: [],
        permissions: { 'fake-user': 'write' },
        checks: [],
      });
      for (const login of repositoryOptions.assignable ?? ['fake-user']) knownLogins.add(login);
    },
    addTag(fullName, tag) {
      const [owner = '', name = ''] = fullName.split('/');
      findRepository(owner, name).tags.push(tag);
    },
    setPermission(fullName, login, permission) {
      const [owner = '', name = ''] = fullName.split('/');
      findRepository(owner, name).permissions[login] = permission;
      knownLogins.add(login);
    },
    setChecks(fullName, states) {
      const [owner = '', name = ''] = fullName.split('/');
      findRepository(owner, name).checks = [...states];
    },
    listMilestones(fullName) {
      const [owner = '', name = ''] = fullName.split('/');
      const repository = findRepository(owner, name);
      return repository.milestones.map((milestone) => ({ title: milestone.title, issues: repository.issues.filter((issue) => issue.milestone?.id === milestone.id).map((issue) => issue.number) }));
    },
    addLabel(owner, label) {
      organizations.add(owner);
      const created: FakeLabel = {
        id: newId(),
        name: label.name,
        color: (label.color ?? 'aaaaaa').toLowerCase(),
        description: label.description ?? '',
        exclusive: label.exclusive ?? false,
        owner,
        repo: undefined,
      };
      labels.push(created);
      return created.id;
    },
    addIssue(fullName, issue) {
      const [owner = '', name = ''] = fullName.split('/');
      const repository = findRepository(owner, name);
      const created: FakeIssue = {
        id: newId(),
        number: repository.issues.length + 1,
        title: issue.title,
        body: issue.body ?? '',
        state: issue.state ?? 'open',
        labels: (issue.labels ?? []).map((labelName) => labelByName(owner, labelName).id),
        assignees: issue.assignees ?? [],
        comments: [],
        events: [],
        milestone: undefined,
        dependencies: [],
        created_at: clock(),
      };
      repository.issues.push(created);
      return created.number;
    },
    addComment(fullName, number, login, body) {
      const [owner = '', name = ''] = fullName.split('/');
      knownLogins.add(login);
      findIssue(findRepository(owner, name), number).comments.push({ id: newId(), login, body, created_at: clock() });
    },
    readIssue(fullName, number) {
      const [owner = '', name = ''] = fullName.split('/');
      const issue = findIssue(findRepository(owner, name), number);
      return {
        title: issue.title,
        body: issue.body,
        state: issue.state,
        labels: issue.labels.map((id) => labels.find((label) => label.id === id)?.name ?? `unknown-${id}`),
        assignees: issue.assignees,
        comments: issue.comments.map((comment) => comment.body),
        dependencies: issue.dependencies.map((reference) => `${reference.owner}/${reference.repo}#${reference.index}`),
        milestone: issue.milestone?.title,
      };
    },
    listLabels(owner) {
      return labels.filter((label) => label.owner === owner && label.repo === undefined).map((label) => ({ name: label.name, color: label.color, description: label.description, exclusive: label.exclusive }));
    },
    fail(rule) {
      rules.push({ ...rule, left: rule.times ?? 1 });
    },
    writes() {
      return requests.filter((request) => request.method !== 'GET');
    },
    close() {
      return new Promise<void>((resolveClosed, rejectClosed) => {
        server.closeAllConnections();
        server.close((error) => (error === undefined ? resolveClosed() : rejectClosed(error)));
      });
    },
  };
}

export function clientFor(fake: FakeForgejo, options: Partial<Pick<ClientOptions, 'connectTimeoutMs' | 'totalTimeoutMs'>> = {}): ForgejoClient {
  return new ForgejoClient({ baseUrl: fake.url, token: createTokenSource(`printf '%s' ${fake.token}`), ...options });
}

export function contextFor(fake: FakeForgejo, overrides: Partial<CommandContext> = {}): CommandContext {
  const client = clientFor(fake);
  return {
    cwd: process.cwd(),
    git: new GitClient(),
    settings: { forgejoUrl: fake.url, tokenCommand: `printf '%s' ${fake.token}`, labelsFile: undefined },
    now: () => new Date(2026, 9, 23, 12, 0, 0),
    api: () => client,
    harness: createRecordingHarness(),
    stderr: () => {},
    ...overrides,
  };
}

// The organization labels a project's tracker holds after labels-sync, as test data.
export function seedLabels(fake: FakeForgejo, owner: string): void {
  const exclusive = ['status/backlog', 'status/ready', 'status/planned', 'status/implementing', 'status/review', 'status/testing', 'status/done', 'status/not-planned', 'priority/p0', 'priority/p1', 'priority/p2', 'priority/p3', 'priority/p9', 'type/bug', 'type/feature'];
  for (const name of exclusive) fake.addLabel(owner, { name, exclusive: true });
  for (const name of ['area/gate', 'area/docs', 'needs:owner', 'closes:test']) fake.addLabel(owner, { name });
}
