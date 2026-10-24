import { ContractError } from './client.mts';
import type { Reader } from './client.mts';

// A wire type is a reader that either returns a value of the type or says what is wrong with it,
// plus the JSON type it reads, which shapes.test.mts compares with api/schema.json.
export type WireKind = 'string' | 'integer' | 'boolean' | 'array' | 'object';

export interface WireType<T> {
  readonly wire: WireKind;
  readonly read: Reader<T>;
}

export interface Field<T> {
  readonly type: WireType<T>;
  readonly required: boolean;
}

export type Spec<T> = { readonly [K in keyof T]-?: Field<T[K]> };

export interface Shape<T> {
  readonly definition: string;
  readonly spec: Spec<T>;
  readonly type: WireType<T>;
}

export const string: WireType<string> = {
  wire: 'string',
  read(value, where) {
    if (typeof value !== 'string') throw new ContractError(where, `a string was expected, not ${describe(value)}`);
    return value;
  },
};

export const integer: WireType<number> = {
  wire: 'integer',
  read(value, where) {
    if (typeof value !== 'number' || !Number.isInteger(value)) throw new ContractError(where, `an integer was expected, not ${describe(value)}`);
    return value;
  },
};

export const boolean: WireType<boolean> = {
  wire: 'boolean',
  read(value, where) {
    if (typeof value !== 'boolean') throw new ContractError(where, `true or false was expected, not ${describe(value)}`);
    return value;
  },
};

function nullable<T>(inner: WireType<T>): WireType<T | null> {
  return { wire: inner.wire, read: (value, where) => (value === null ? null : inner.read(value, where)) };
}

export function arrayOf<T>(item: WireType<T>): WireType<T[]> {
  return {
    wire: 'array',
    read(value, where) {
      if (!Array.isArray(value)) throw new ContractError(where, `a list was expected, not ${describe(value)}`);
      return value.map((entry: unknown, index: number) => item.read(entry, `${where}[${index}]`));
    },
  };
}

export function required<T>(type: WireType<T>): Field<T> {
  return { type, required: true };
}

export function optional<T>(type: WireType<T>): Field<T | undefined> {
  return { type: { wire: type.wire, read: (value, where) => (value === undefined ? undefined : type.read(value, where)) }, required: false };
}

function defineShape<T>(definition: string, spec: Spec<T>): Shape<T> {
  const entries = Object.entries(spec) as [string, Field<unknown>][];
  const type: WireType<T> = {
    wire: 'object',
    read(value, where) {
      if (typeof value !== 'object' || value === null || Array.isArray(value)) {
        throw new ContractError(where, `${definition} was expected, not ${describe(value)}`);
      }
      const record = value as Record<string, unknown>;
      const result: Record<string, unknown> = {};
      for (const [name, field] of entries) {
        const present = record[name];
        if (present === undefined && field.required) throw new ContractError(where, `${definition} lacks the required field ${name}`);
        result[name] = field.type.read(present, `${where}.${name}`);
      }
      return result as T;
    },
  };
  return { definition, spec, type };
}

function describe(value: unknown): string {
  if (value === null) return 'null';
  if (value === undefined) return 'nothing';
  if (Array.isArray(value)) return 'a list';
  return typeof value === 'object' ? 'an object' : `a ${typeof value}`;
}

export interface User {
  readonly login: string;
}
export const userShape = defineShape<User>('User', { login: required(string) });

export interface Label {
  readonly id: number;
  readonly name: string;
  readonly color: string;
  readonly description: string | undefined;
  readonly exclusive: boolean | undefined;
}
export const labelShape = defineShape<Label>('Label', {
  id: required(integer),
  name: required(string),
  color: required(string),
  description: optional(string),
  exclusive: optional(boolean),
});

export interface RepositoryMeta {
  readonly full_name: string;
}
export const repositoryMetaShape = defineShape<RepositoryMeta>('RepositoryMeta', { full_name: required(string) });

export interface Milestone {
  readonly id: number;
  readonly title: string;
}
export const milestoneShape = defineShape<Milestone>('Milestone', { id: required(integer), title: required(string) });

export interface Issue {
  readonly number: number;
  readonly title: string;
  readonly body: string;
  readonly state: string;
  readonly labels: Label[] | null;
  readonly assignees: User[] | null;
  readonly comments: number;
  readonly created_at: string;
  readonly html_url: string;
  readonly repository: RepositoryMeta | undefined;
  readonly milestone: Milestone | null | undefined;
}
export const issueShape = defineShape<Issue>('Issue', {
  number: required(integer),
  title: required(string),
  body: required(string),
  state: required(string),
  labels: required(nullable(arrayOf(labelShape.type))),
  assignees: required(nullable(arrayOf(userShape.type))),
  comments: required(integer),
  created_at: required(string),
  html_url: required(string),
  repository: optional(repositoryMetaShape.type),
  milestone: optional(nullable(milestoneShape.type)),
});

export interface Comment {
  readonly id: number;
  readonly html_url: string;
  readonly body: string;
  readonly created_at: string;
  readonly user: User | null;
}
export const commentShape = defineShape<Comment>('Comment', {
  id: required(integer),
  html_url: required(string),
  body: required(string),
  created_at: required(string),
  user: required(nullable(userShape.type)),
});

export interface Repository {
  readonly full_name: string;
  readonly private: boolean;
  readonly default_branch: string;
}
export const repositoryShape = defineShape<Repository>('Repository', {
  full_name: required(string),
  private: required(boolean),
  default_branch: required(string),
});

export interface Tag {
  readonly name: string;
}
export const tagShape = defineShape<Tag>('Tag', { name: required(string) });

// One entry of the timeline of an issue: a comment, and the events (close, reopen, milestone, ...) that
// are no comment. Forgejo names the kind of each in `type`.
export interface TimelineEvent {
  readonly id: number;
  readonly type: string;
  readonly body: string;
  readonly created_at: string;
  readonly user: User | null;
  readonly milestone: Milestone | null | undefined;
  readonly label: Label | null | undefined;
}
export const timelineEventShape = defineShape<TimelineEvent>('TimelineComment', {
  id: required(integer),
  type: required(string),
  body: required(string),
  created_at: required(string),
  user: required(nullable(userShape.type)),
  milestone: optional(nullable(milestoneShape.type)),
  label: optional(nullable(labelShape.type)),
});

export interface CollaboratorPermission {
  readonly permission: string;
}
export const collaboratorPermissionShape = defineShape<CollaboratorPermission>('RepoCollaboratorPermission', { permission: required(string) });

// Forgejo answers an empty object for a commit that no check has reported on.
export interface CombinedStatus {
  readonly state: string | undefined;
  readonly total_count: number | undefined;
}
export const combinedStatusShape = defineShape<CombinedStatus>('CombinedStatus', { state: optional(string), total_count: optional(integer) });

// The bodies the client sends. The fake Forgejo refuses a field these do not name.
export interface CreateIssueBody {
  readonly title: string;
  readonly body?: string;
  readonly labels?: readonly number[];
  readonly assignees?: readonly string[];
  readonly closed?: boolean;
}
export interface EditIssueBody {
  readonly title?: string;
  readonly body?: string;
  readonly state?: 'open' | 'closed';
  readonly assignees?: readonly string[];
  readonly milestone?: number;
}
export interface CreateMilestoneBody {
  readonly title: string;
}
export interface CreateCommentBody {
  readonly body: string;
}
export interface IssueLabelsBody {
  readonly labels: readonly number[];
}
export interface IssueMetaBody {
  readonly owner: string;
  readonly repo: string;
  readonly index: number;
}
export interface CreateLabelBody {
  readonly name: string;
  readonly color: string;
  readonly description?: string;
  readonly exclusive?: boolean;
}
export interface EditLabelBody {
  readonly name?: string;
  readonly color?: string;
  readonly description?: string;
  readonly exclusive?: boolean;
}

export interface ShapeDescription {
  readonly definition: string;
  readonly spec: Readonly<Record<string, Field<unknown>>>;
}

export const allShapes: readonly ShapeDescription[] = [
  userShape,
  labelShape,
  repositoryMetaShape,
  milestoneShape,
  issueShape,
  commentShape,
  repositoryShape,
  tagShape,
  timelineEventShape,
  collaboratorPermissionShape,
  combinedStatusShape,
];
