import { ContractError, PartialCompletionError, segment } from '../api/client.mts';
import type { ForgejoClient } from '../api/client.mts';
import { arrayOf, commentShape, issueShape, userShape } from '../api/shapes.mts';
import type { CreateCommentBody, CreateIssueBody, EditIssueBody, Issue as WireIssue } from '../api/shapes.mts';
import { UsageError } from './refusals.mts';

export interface RepositoryRef {
  readonly owner: string;
  readonly repo: string;
}

// A domain reference to an issue. `number` is the number a person sees and the `index` of the API
// path; it is never the database `id`.
export interface IssueRef extends RepositoryRef {
  readonly number: number;
}

export type IssueState = 'open' | 'closed';

const STATE_FILTERS = ['open', 'closed', 'all'] as const;
export type StateFilter = (typeof STATE_FILTERS)[number];

export function parseStateFilter(text: string): StateFilter {
  const found = STATE_FILTERS.find((filter) => filter === text);
  if (found === undefined) throw new UsageError(`--state must be open, closed or all, not '${text}'`);
  return found;
}

export interface Issue {
  readonly ref: IssueRef;
  readonly title: string;
  readonly body: string;
  readonly state: IssueState;
  readonly labels: readonly string[];
  readonly assignees: readonly string[];
  readonly commentCount: number;
  readonly createdAt: string;
  readonly closedAt: string | undefined;
  readonly url: string;
  readonly milestone: { readonly id: number; readonly title: string } | undefined;
}

export interface IssueComment {
  readonly author: string;
  readonly createdAt: string;
  readonly body: string;
  readonly url: string;
}

// The JSON that `issue-thread --json` prints, which session-start and the engine guard read: the
// object lib/github/tracker.sh prints, and the logins the issue is assigned to.
export interface Thread {
  readonly number: number;
  readonly title: string;
  readonly createdAt: string;
  readonly state: IssueState;
  readonly labels: readonly string[];
  readonly assignees: readonly string[];
  readonly body: string;
  readonly comments: readonly { readonly author: string; readonly created_at: string; readonly body: string }[];
}

export function parseRepository(text: string): RepositoryRef {
  const match = /^([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)$/.exec(text);
  if (match?.[1] === undefined || match[2] === undefined) throw new UsageError(`${text} is not OWNER/REPO`);
  return { owner: match[1], repo: match[2] };
}

export function parseOwner(text: string): string {
  if (!/^[A-Za-z0-9_.-]+$/.test(text)) throw new UsageError(`${text} is not the name of an organisation or a user`);
  return text;
}

export function parseIssueNumber(text: string): number {
  if (!/^[1-9][0-9]*$/.test(text)) throw new UsageError(`the issue number must be a positive number, not '${text}'`);
  return Number(text);
}

export function formatRepository(repository: RepositoryRef): string {
  return `${repository.owner}/${repository.repo}`;
}

export function formatIssue(ref: IssueRef): string {
  return `${formatRepository(ref)}#${ref.number}`;
}

// How a commit of the code repository names the issue at the end of its subject, as integrate-issue writes it: #<n> for
// an issue of that repository, OWNER/REPO#<n> for one of another.
export function commitNameOf(ref: IssueRef, codeRepository: RepositoryRef): string {
  return isSameRepository(ref, codeRepository) ? `#${ref.number}` : formatIssue(ref);
}

const SLUG_LENGTH = 40;

// The name start-issue gives the branch of an issue: issue-<number>-<slug>, the slug the title in lower case, every run of
// other characters than letters and digits one hyphen, cut to forty characters.
export function issueBranchName(number: number, title: string): string {
  const slug = title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, SLUG_LENGTH)
    .replace(/-+$/, '');
  return `issue-${number}-${slug}`.replace(/-$/, '');
}

export function isSameIssue(a: IssueRef, b: IssueRef): boolean {
  return a.number === b.number && a.owner.toLowerCase() === b.owner.toLowerCase() && a.repo.toLowerCase() === b.repo.toLowerCase();
}

export function isSameRepository(a: RepositoryRef, b: RepositoryRef): boolean {
  return a.owner.toLowerCase() === b.owner.toLowerCase() && a.repo.toLowerCase() === b.repo.toLowerCase();
}

export function repositoryPath(repository: RepositoryRef): string {
  return `/repos/${segment(repository.owner)}/${segment(repository.repo)}`;
}

export function issuePath(ref: IssueRef): string {
  return `${repositoryPath(ref)}/issues/${segment(ref.number)}`;
}

function toIssue(wire: WireIssue, ref: IssueRef, operation: string): Issue {
  if (wire.state !== 'open' && wire.state !== 'closed') throw new ContractError(operation, `the issue state is '${wire.state}', not open or closed`);
  return {
    ref,
    title: wire.title,
    body: wire.body,
    state: wire.state,
    labels: (wire.labels ?? []).map((label) => label.name),
    assignees: (wire.assignees ?? []).map((user) => user.login),
    commentCount: wire.comments,
    createdAt: wire.created_at,
    closedAt: wire.closed_at ?? undefined,
    url: wire.html_url,
    milestone: wire.milestone === null || wire.milestone === undefined ? undefined : { id: wire.milestone.id, title: wire.milestone.title },
  };
}

export async function getIssue(api: ForgejoClient, ref: IssueRef): Promise<Issue> {
  const name = `read issue ${formatIssue(ref)}`;
  const wire = await api.call({ name, method: 'GET', path: issuePath(ref), success: 200, read: issueShape.type.read });
  return confirmIssue(toIssue(wire, ref, name), ref, wire.number, name);
}

function confirmIssue(issue: Issue, ref: IssueRef, answered: number, name: string): Issue {
  if (answered !== ref.number) throw new ContractError(name, `Forgejo answered issue ${answered}`);
  return issue;
}

export interface NewIssue {
  readonly title: string;
  readonly body: string;
  readonly labels: readonly { readonly id: number; readonly name: string }[];
  readonly assignees: readonly string[];
}

export async function createIssue(api: ForgejoClient, repository: RepositoryRef, input: NewIssue): Promise<Issue> {
  const name = `create an issue in ${formatRepository(repository)}`;
  const body: CreateIssueBody = { title: input.title, body: input.body, labels: input.labels.map((label) => label.id), assignees: input.assignees };
  const wire = await api.call({ name, method: 'POST', path: `${repositoryPath(repository)}/issues`, body, success: 201, read: issueShape.type.read });
  const issue = toIssue(wire, { ...repository, number: wire.number }, name);
  const wanted = input.labels.map((label) => label.name).sort();
  if ([...issue.labels].sort().join('\n') !== wanted.join('\n')) {
    throw new PartialCompletionError(name, [`created ${formatIssue(issue.ref)}`], `it carries ${issue.labels.join(', ') || 'no labels'} instead of ${wanted.join(', ')}; do not create it again`);
  }
  const wantedAssignees = input.assignees.map((login) => login.toLowerCase()).sort();
  if (issue.assignees.map((login) => login.toLowerCase()).sort().join('\n') !== wantedAssignees.join('\n')) {
    throw new PartialCompletionError(name, [`created ${formatIssue(issue.ref)}`], `it is assigned to ${issue.assignees.join(', ') || 'nobody'} instead of ${input.assignees.join(', ')}; do not create it again`);
  }
  return issue;
}

export async function editIssue(api: ForgejoClient, ref: IssueRef, edit: EditIssueBody): Promise<Issue> {
  const name = `edit issue ${formatIssue(ref)}`;
  const wire = await api.call({ name, method: 'PATCH', path: issuePath(ref), body: edit, success: 201, read: issueShape.type.read });
  return confirmIssue(toIssue(wire, ref, name), ref, wire.number, name);
}

export async function addComment(api: ForgejoClient, ref: IssueRef, body: string): Promise<IssueComment> {
  const name = `comment on issue ${formatIssue(ref)}`;
  const request: CreateCommentBody = { body };
  const wire = await api.call({ name, method: 'POST', path: `${issuePath(ref)}/comments`, body: request, success: 201, read: commentShape.type.read });
  return { author: wire.user?.login ?? '', createdAt: wire.created_at, body: wire.body, url: wire.html_url };
}

// The whole thread. The comment list documents no paging, so its length is held against the count
// the issue itself states: a shorter list is refused and never read as a shorter thread.
export async function readComments(api: ForgejoClient, ref: IssueRef, expectedCount: number): Promise<IssueComment[]> {
  const name = `read the comments of issue ${formatIssue(ref)}`;
  const wires = await api.call({ name, method: 'GET', path: `${issuePath(ref)}/comments`, success: 200, read: arrayOf(commentShape.type).read });
  if (wires.length < expectedCount) throw new ContractError(name, `the issue states ${expectedCount} comments and Forgejo listed ${wires.length}`);
  return wires.map((wire) => ({ author: wire.user?.login ?? '', createdAt: wire.created_at, body: wire.body, url: wire.html_url }));
}

export async function readThread(api: ForgejoClient, ref: IssueRef): Promise<Thread> {
  const issue = await getIssue(api, ref);
  const comments = await readComments(api, ref, issue.commentCount);
  return {
    number: issue.ref.number,
    title: issue.title,
    createdAt: issue.createdAt,
    state: issue.state,
    labels: issue.labels,
    assignees: issue.assignees,
    body: issue.body,
    comments: comments.map((comment) => ({ author: comment.author, created_at: comment.createdAt, body: comment.body })),
  };
}

export async function listAssignable(api: ForgejoClient, repository: RepositoryRef): Promise<string[]> {
  const name = `list who can be assigned in ${formatRepository(repository)}`;
  const users = await api.call({ name, method: 'GET', path: `${repositoryPath(repository)}/assignees`, success: 200, read: arrayOf(userShape.type).read });
  return users.map((user) => user.login);
}

export async function setAssignees(api: ForgejoClient, ref: IssueRef, logins: readonly string[]): Promise<Issue> {
  const issue = await editIssue(api, ref, { assignees: logins });
  const expected = [...logins].map((login) => login.toLowerCase()).sort();
  const actual = [...issue.assignees].map((login) => login.toLowerCase()).sort();
  if (expected.join('\n') !== actual.join('\n')) {
    throw new ContractError(`set the assignees of issue ${formatIssue(ref)}`, `Forgejo kept ${actual.join(', ') || 'nobody'} instead of ${expected.join(', ') || 'nobody'}`);
  }
  return issue;
}

// Why the signed-in account may not take the issue up, or nothing when it is assigned to it. An issue assigned
// to nobody is refused too: the product owner assigns it first.
export function explainMissingAssignment(issue: Issue, login: string): string | undefined {
  if (issue.assignees.some((assignee) => assignee.toLowerCase() === login.toLowerCase())) return undefined;
  const name = formatIssue(issue.ref);
  if (issue.assignees.length === 0) return `${name} is assigned to nobody: the product owner assigns it before it is taken up`;
  return `${name} is assigned to ${issue.assignees.map((assignee) => `@${assignee}`).join(', ')}, not to @${login}: ask them or the product owner to reassign it`;
}

export async function currentLogin(api: ForgejoClient): Promise<string> {
  const user = await api.call({ name: 'read the signed-in user', method: 'GET', path: '/user', success: 200, read: userShape.type.read });
  return user.login;
}

function searchWordsOf(text: string): string[] {
  return text.split(/\s+/).filter((word) => word !== '');
}

// Every word of the text as a quoted term, which Forgejo's search reads as that word and never as one of its operators
// (`is:closed`, `author:`, `-word`).
export function searchTermsOf(text: string): string {
  return searchWordsOf(text)
    .map((word) => `"${word.replace(/[\\"]/g, '\\$&')}"`)
    .join(' ');
}

// Forgejo's search reads the comments too, and its database indexer searches only the last term (db.go and bleve.go of
// modules/indexer/issues at v17.0.1), so its answer is read again: the title or the body holds every word, in any case.
function holdsEveryWord(issue: Issue, words: readonly string[]): boolean {
  const text = `${issue.title}\n${issue.body}`.toLowerCase();
  return words.every((word) => text.includes(word.toLowerCase()));
}

export async function searchIssues(api: ForgejoClient, owner: string, state: StateFilter, text?: string): Promise<(Issue & { repository: RepositoryRef })[]> {
  const name = `search the issues of ${owner}`;
  const words = text === undefined ? [] : searchWordsOf(text);
  const query = { type: 'issues', state, owner, q: text === undefined ? undefined : searchTermsOf(text) };
  const wires = await api.callAll({ name, path: '/repos/issues/search', query, readItem: issueShape.type.read });
  return wires
    .map((wire) => {
      const fullName = wire.repository?.full_name;
      if (fullName === undefined) throw new ContractError(name, `issue ${wire.number} names no repository`);
      const repository = parseRepositoryFromAnswer(fullName, name);
      return { ...toIssue(wire, { ...repository, number: wire.number }, name), repository };
    })
    .filter((issue) => holdsEveryWord(issue, words));
}

function parseRepositoryFromAnswer(fullName: string, name: string): RepositoryRef {
  try {
    return parseRepository(fullName);
  } catch {
    throw new ContractError(name, `'${fullName}' is not OWNER/REPO`);
  }
}

// The line that opens every issue body: who asked for the work, or where a defect or another finding was found.
const ASKED_PREFIX = 'Asked for by @';
const FOUND_PREFIX = 'Found in ';
const FOUND_TAIL = ' filed without a yes.';
const MOVED_ADDRESS = /^https:\/\/[^\s/]+\/[^\s/]+\/[^\s/]+\/issues\/[0-9]+$/;

export type Provenance = { readonly askedBy: string; readonly askedIn: string } | { readonly foundIn: string; readonly isDefect: boolean };

export function composeOriginLine(provenance: Provenance, today: string): string {
  if ('foundIn' in provenance) return `${FOUND_PREFIX}${provenance.foundIn} on ${today}, ${provenance.isDefect ? 'a defect' : 'a finding'}${FOUND_TAIL}`;
  return `${ASKED_PREFIX}${provenance.askedBy.replace(/^@/, '')} on ${today} in ${provenance.askedIn}.`;
}

// Whether a line is one that names who asked, where a defect was found, or the address an issue
// was moved from. Those lines are never dropped by an edit.
export function isOriginLine(line: string): boolean {
  return line.startsWith(ASKED_PREFIX) || (line.startsWith(FOUND_PREFIX) && line.endsWith(FOUND_TAIL)) || MOVED_ADDRESS.test(line);
}

// The body an edit sends: the new body, with the issue's own first line put back where the new
// body does not open with such a line itself.
export function keepOriginLine(currentBody: string, newBody: string): { readonly body: string; readonly kept: boolean } {
  const newFirst = newBody.split('\n', 1)[0] ?? '';
  const currentFirst = currentBody.split('\n', 1)[0] ?? '';
  if (isOriginLine(newFirst) || !isOriginLine(currentFirst)) return { body: newBody, kept: false };
  return { body: `${currentFirst}\n\n${newBody}`, kept: true };
}

// Runs the action for each item in order. A failure after the first success is a partial
// completion that names what was done; a failure of the first changes nothing and is passed on.
export async function applyInOrder<T>(operation: string, items: readonly T[], describe: (item: T) => string, action: (item: T) => Promise<void>): Promise<void> {
  const done: string[] = [];
  for (const item of items) {
    try {
      await action(item);
    } catch (error) {
      if (error instanceof PartialCompletionError) throw new PartialCompletionError(operation, [...done, ...error.completed], error.message);
      if (done.length === 0) throw error;
      throw new PartialCompletionError(operation, done, `${describe(item)} failed: ${error instanceof Error ? error.message : String(error)}`);
    }
    done.push(describe(item));
  }
}

// A step that follows a step already taken: its failure leaves the work partly done, and says so.
export async function afterStep(operation: string, stepTaken: string, action: () => Promise<unknown>): Promise<void> {
  try {
    await action();
  } catch (error) {
    throw new PartialCompletionError(operation, [stepTaken], error instanceof Error ? error.message : String(error));
  }
}
