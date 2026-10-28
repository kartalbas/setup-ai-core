import { ContractError, NotFoundError, PermissionError, segment } from '../api/client.mts';
import type { ForgejoClient } from '../api/client.mts';
import { collaboratorPermissionShape, timelineEventShape } from '../api/shapes.mts';
import type { TimelineEvent } from '../api/shapes.mts';
import { formatIssue, formatRepository, isSameRepository, issuePath, parseRepository, repositoryPath } from './issues.mts';
import type { Issue, IssueRef, RepositoryRef } from './issues.mts';
import { UsageError } from './refusals.mts';

// The records the workflow writes into an issue at the moment a fact happens, and the reading of them. A
// card's state is never rebuilt from commit messages or release history: it is what these records say.
//
//   Started on <branch>:                      the work began
//   Landed on <branch>[ of <owner/repo>]:     the reviewed work reached the default branch
//   Landed part on <branch>[ of <owner/repo>]: a part of the work did, and more is to follow: the landing of that
//                                             repository for its release and its delivery, never the issue's landing
//   Released in <owner/repo> <tag>:           a release of that repository carries the work
//   Proven on <environment>:                  the delivered work was seen to work there

export interface StartedRecord {
  readonly branch: string;
  readonly baseBranch: string;
  readonly baseCommit: string;
}

export interface LandedRecord {
  // The default branch the work landed on.
  readonly branch: string;
  // The repository the work landed in.
  readonly repository: RepositoryRef;
  readonly reviewedHead: string;
  readonly landedCommit: string;
  readonly reviewers: readonly string[];
  // A part with more to follow: the record says so, and the card keeps its status.
  readonly isPart?: boolean;
}

export function composeStartedRecord(record: StartedRecord): string {
  return `Started on ${record.branch}:\n\nBase: ${record.baseBranch} at ${record.baseCommit}\n`;
}

// "Landed on master:" when the work landed in the repository of the issue, else "Landed on master of owner/repo:".
export function composeLandedRecord(record: LandedRecord, issueRepository: RepositoryRef): string {
  const where = isSameRepository(record.repository, issueRepository) ? '' : ` of ${formatRepository(record.repository)}`;
  return `Landed ${record.isPart === true ? 'part on' : 'on'} ${record.branch}${where}:\n\nReviewed head: ${record.reviewedHead}\nLanded commit: ${record.landedCommit}\nReviewed by: ${record.reviewers.join(', ')}\n`;
}

export function composeReleasedRecord(repository: RepositoryRef, tag: string): string {
  return `Released in ${formatRepository(repository)} ${tag}:\n`;
}

export function composeProvenRecord(environment: string, evidence: string): string {
  return `Proven on ${environment}:\n\n${evidence.trimEnd()}\n`;
}

const NAME = '[A-Za-z0-9_.-]+';
const LANDED_LINE = new RegExp(`^Landed on ([^\\s:]+)(?: of (${NAME}/${NAME}))?:$`);
const LANDED_PART_LINE = new RegExp(`^Landed part on ([^\\s:]+)(?: of (${NAME}/${NAME}))?:$`);
const RELEASED_LINE = new RegExp(`^Released in (${NAME}/${NAME}) (\\S+):$`);
const PROVEN_LINE = /^Proven on ([^\s:]+)[^:]*:$/;
const STARTED_LINE = /^Started on ([^\s:]+):$/;

function firstLine(body: string): string {
  return (body.split('\n', 1)[0] ?? '').replace(/\r$/, '').trimEnd();
}

function fieldOf(body: string, label: string): string | undefined {
  const match = new RegExp(`^${label}: (\\S.*)$`, 'm').exec(body);
  return match?.[1]?.trim();
}

// --- the timeline ------------------------------------------------------------

export interface TimelineEntry {
  readonly kind: 'comment' | 'reopen' | 'close' | 'milestone' | 'label' | 'other';
  // Milliseconds since 1970: a time is compared as an instant, never as text.
  readonly at: number;
  readonly author: string;
  readonly body: string;
  readonly milestoneTitle: string | undefined;
  readonly labelName: string | undefined;
}

function kindOf(type: string): TimelineEntry['kind'] {
  return type === 'comment' || type === 'reopen' || type === 'close' || type === 'milestone' || type === 'label' ? type : 'other';
}

function instantOf(text: string, name: string): number {
  const instant = Date.parse(text);
  if (Number.isNaN(instant) || !/(Z|[+-][0-9]{2}:[0-9]{2})$/.test(text)) throw new ContractError(name, `'${text}' is no time with a zone`);
  return instant;
}

// The comments and the events of the issue, every page of them. Forgejo answers null for an event whose
// issue, comment, label or milestone it cannot load (services/convert/issue_comment.go of v17.0.0); a
// comment refers to none of these, so leaving such an entry out loses no record.
export async function readTimeline(api: ForgejoClient, ref: IssueRef): Promise<TimelineEntry[]> {
  const name = `read the timeline of issue ${formatIssue(ref)}`;
  const readItem = (item: unknown, where: string): TimelineEvent | undefined => (item === null ? undefined : timelineEventShape.type.read(item, where));
  const answers = await api.callAll({ name, path: `${issuePath(ref)}/timeline`, readItem, totalCountsPage: true });
  const wires = answers.filter((wire): wire is TimelineEvent => wire !== undefined);
  return wires.map((wire) => ({
    kind: kindOf(wire.type),
    at: instantOf(wire.created_at, name),
    author: wire.user?.login ?? '',
    body: wire.body,
    milestoneTitle: wire.milestone?.title,
    labelName: wire.label?.name,
  }));
}

// --- who counts ---------------------------------------------------------------

const WRITING_PERMISSIONS: readonly string[] = ['write', 'admin', 'owner'];

// Whether an account may write to the repository. A record counts only from such an account, because on a
// public repository anybody can write "Landed on" or "Proven on". An account Forgejo does not know has no
// permission. A refused read is an error: it is never taken for "no permission".
export function createTrustCheck(api: ForgejoClient, repository: RepositoryRef): (login: string) => Promise<boolean> {
  const answers = new Map<string, boolean>();
  return async (login) => {
    const known = answers.get(login);
    if (known !== undefined) return known;
    const name = `read the permission of ${login} in ${formatRepository(repository)}`;
    let trusted: boolean;
    try {
      const found = await api.call({ name, method: 'GET', path: `${repositoryPath(repository)}/collaborators/${segment(login)}/permission`, success: 200, read: collaboratorPermissionShape.type.read });
      trusted = WRITING_PERMISSIONS.includes(found.permission);
    } catch (error) {
      if (error instanceof NotFoundError) trusted = false;
      else if (error instanceof PermissionError) {
        throw new PermissionError(name, `${error.message.slice(name.length + 2)}. Forgejo lets only an administrator of the repository read the permission of another account`);
      } else throw error;
    }
    answers.set(login, trusted);
    return trusted;
  };
}

// --- the history of an issue ---------------------------------------------------

export interface LandingFact {
  readonly index: number;
  readonly at: number;
  readonly repository: RepositoryRef;
  readonly branch: string;
  readonly commit: string | undefined;
  // A "Landed part on" record: it lands its repository, and the issue's work is not all landed with it.
  readonly isPart: boolean;
}

export interface ReleaseFact {
  readonly index: number;
  readonly repository: RepositoryRef;
  readonly tag: string;
}

export interface ProofFact {
  readonly index: number;
  readonly environment: string;
}

export interface IssueHistory {
  readonly deliveryReopenedAt: number | undefined;
  readonly landings: readonly LandingFact[];
  readonly releases: readonly ReleaseFact[];
  readonly proofs: readonly ProofFact[];
}

async function isTestingReopening(entries: readonly TimelineEntry[], isTrusted: (login: string) => Promise<boolean>): Promise<boolean> {
  for (const entry of entries) {
    if (entry.kind !== 'label' || entry.body !== '1' || !entry.labelName?.startsWith('status/')) continue;
    if (await isTrusted(entry.author)) return entry.labelName === 'status/testing';
  }
  return false;
}

export async function readIssueHistory(api: ForgejoClient, issue: Issue, entries: readonly TimelineEntry[]): Promise<IssueHistory> {
  const isTrusted = createTrustCheck(api, issue.ref);
  const reopenings = entries.flatMap((entry, index) => entry.kind === 'reopen' ? [index] : []);
  const lastReopening = reopenings[reopenings.length - 1];
  let deliveryStart = 0;
  for (const [index, reopening] of reopenings.entries()) {
    if (!(await isTestingReopening(entries.slice(reopening + 1, reopenings[index + 1]), isTrusted))) deliveryStart = reopening + 1;
  }
  const deliveryReopenedAt = entries[deliveryStart - 1]?.at;
  const current = entries.slice(deliveryStart);

  const landings: LandingFact[] = [];
  const releases: ReleaseFact[] = [];
  const proofs: ProofFact[] = [];
  for (const [index, entry] of current.entries()) {
    if (entry.kind !== 'comment') continue;
    const line = firstLine(entry.body);
    const landedPart = LANDED_PART_LINE.exec(line);
    const landed = LANDED_LINE.exec(line) ?? landedPart;
    const released = RELEASED_LINE.exec(line);
    const proven = PROVEN_LINE.exec(line);
    if (landed === null && released === null && proven === null) continue;
    if (!(await isTrusted(entry.author))) continue;
    if (landed?.[1] !== undefined) landings.push({ index, at: entry.at, branch: landed[1], repository: landed[2] === undefined ? { owner: issue.ref.owner, repo: issue.ref.repo } : parseRepository(landed[2]), commit: fieldOf(entry.body, 'Landed commit'), isPart: landedPart !== null });
    if (released?.[1] !== undefined && released[2] !== undefined) releases.push({ index, repository: parseRepository(released[1]), tag: released[2] });
    if (proven?.[1] !== undefined && (lastReopening === undefined || index + deliveryStart > lastReopening)) proofs.push({ index, environment: proven[1] });
  }

  // A milestone is a release of the issue's own repository. Its event is written by an account that may edit the issue.
  if (issue.milestone !== undefined) {
    const index = current.findLastIndex((entry) => entry.kind === 'milestone');
    const latest = current[index];
    if (latest?.milestoneTitle === issue.milestone.title) releases.push({ index, repository: { owner: issue.ref.owner, repo: issue.ref.repo }, tag: issue.milestone.title });
  }
  return { deliveryReopenedAt, landings, releases, proofs };
}

// --- the facts the commands decide by -------------------------------------------

function newest<T extends { readonly index: number }>(facts: readonly T[]): T | undefined {
  return facts.reduce<T | undefined>((latest, fact) => (latest === undefined || fact.index > latest.index ? fact : latest), undefined);
}

// A harness layer is never released: init assembles every checkout it serves from its default branch.
export function isHarnessLayer(repository: RepositoryRef): boolean {
  const name = repository.repo.toLowerCase();
  return name.endsWith('-ai-core') && name !== 'setup-ai-core';
}

export function findNewestLanding(history: IssueHistory, repository: RepositoryRef): LandingFact | undefined {
  return newest(history.landings.filter((landing) => isSameRepository(landing.repository, repository)));
}

// What a project's reader told of a repository whose LIVE_TAGS names the environment with the pattern command:
// nothing missing, or why its landing is not delivered.
export interface CommandDeliveryCheck {
  readonly repository: RepositoryRef;
  readonly missing: string | undefined;
}

// The lines that say why the work is not delivered; none when it is. A repository the work landed in is
// delivered by a release that came after its landing, where its landing is its delivery by the landing, and
// where a reader answers its delivery by what that reader told.
export function listMissingDelivery(history: IssueHistory, landingIsDelivery: readonly RepositoryRef[], commandDeliveries: readonly CommandDeliveryCheck[] = []): string[] {
  const landing = newest(history.landings);
  if (landing === undefined || landing.isPart) {
    const since = history.deliveryReopenedAt === undefined ? 'the start of the issue' : 'the last reopening for new work';
    return [landing === undefined
      ? `no "Landed on" record of an account with write permission follows ${since}`
      : 'the newest landing record is "Landed part on": the last part lands without --part'];
  }
  const missing: string[] = [];
  const seen = new Set<string>();
  for (const landing of history.landings) {
    const key = formatRepository(landing.repository).toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    if (isHarnessLayer(landing.repository) || landingIsDelivery.some((repository) => isSameRepository(repository, landing.repository))) continue;
    const check = commandDeliveries.find((delivery) => isSameRepository(delivery.repository, landing.repository));
    if (check !== undefined) {
      if (check.missing !== undefined) missing.push(check.missing);
      continue;
    }
    const latestLanding = findNewestLanding(history, landing.repository);
    const released = history.releases.some((release) => isSameRepository(release.repository, landing.repository) && latestLanding !== undefined && release.index > latestLanding.index);
    if (!released) missing.push(`no release of ${formatRepository(landing.repository)} follows its landing: issue-release --repo ${formatRepository(landing.repository)} --tag TAG`);
  }
  return missing;
}

// A proof counts once the newest landing is behind it and is not a part with more to follow.
// Where the issue holds no landing record at all (`delivered without code`), its work
// was no change of code, and the newest proof after its last reopening counts.
export function findCurrentProof(history: IssueHistory, deliveredWithoutCode = false): ProofFact | undefined {
  const landing = newest(history.landings);
  if (landing === undefined) return deliveredWithoutCode ? newest(history.proofs) : undefined;
  if (landing.isPart) return undefined;
  return newest(history.proofs.filter((proof) => proof.index > landing.index));
}

// Whether the issue holds no "Landed on" or "Landed part on" record, from any account: its delivery was no change of code.
export function holdsNoLandedRecord(entries: readonly TimelineEntry[]): boolean {
  return !entries.some((entry) => entry.kind === 'comment' && (LANDED_LINE.test(firstLine(entry.body)) || LANDED_PART_LINE.test(firstLine(entry.body))));
}

// The entries of LIVE_TAGS (`env=pattern` separated by spaces), each environment with its pattern.
function readLiveTagsEntries(liveTags: string | undefined): { environment: string; pattern: string }[] {
  return (liveTags ?? '').split(/\s+/).filter((text) => text !== '').map((entry) => {
    const equals = entry.indexOf('=');
    if (equals <= 0 || equals === entry.length - 1) throw new UsageError(`LIVE_TAGS has '${entry}' where env=pattern belongs`);
    return { environment: entry.slice(0, equals), pattern: entry.slice(equals + 1) };
  });
}

// Every environment LIVE_TAGS names, as it spells them.
export function environmentNames(liveTags: string | undefined): string[] {
  return readLiveTagsEntries(liveTags).map(({ environment }) => environment);
}

// The environments of LIVE_TAGS whose pattern is the one given.
export function environmentsWith(liveTags: string | undefined, pattern: string): string[] {
  return readLiveTagsEntries(liveTags).filter((entry) => entry.pattern === pattern).map(({ environment }) => environment);
}

// The environments whose pattern is `landed`: there the landing is the delivery.
export function landedEnvironments(liveTags: string | undefined): string[] {
  return environmentsWith(liveTags, 'landed');
}

// --- finding a record that is already written ---------------------------------------

export function hasStartedRecord(entries: readonly TimelineEntry[], branch: string): boolean {
  return entries.some((entry) => entry.kind === 'comment' && STARTED_LINE.exec(firstLine(entry.body))?.[1] === branch);
}

// Whether the issue carries the record of this landing: of a part with more to follow where `isPart`, else of the landing.
export function hasLandedRecord(entries: readonly TimelineEntry[], reviewedHead: string, landedCommit: string, isPart = false): boolean {
  const line = isPart ? LANDED_PART_LINE : LANDED_LINE;
  return entries.some((entry) => entry.kind === 'comment' && line.test(firstLine(entry.body)) && fieldOf(entry.body, 'Reviewed head') === reviewedHead && fieldOf(entry.body, 'Landed commit') === landedCommit);
}

// Whether the issue carries the landing of this head: a "Landed on" record of an account with write permission
// that names the reviewed head and the landed commit.
export async function hasTrustedLandedRecord(api: ForgejoClient, ref: IssueRef, entries: readonly TimelineEntry[], reviewedHead: string, landedCommit: string): Promise<boolean> {
  const isTrusted = createTrustCheck(api, ref);
  for (const entry of entries) {
    if (!hasLandedRecord([entry], reviewedHead, landedCommit)) continue;
    if (await isTrusted(entry.author)) return true;
  }
  return false;
}

// The reviewed heads that the "Landed on" records of accounts with write permission name, in the order written.
export async function listTrustedLandedHeads(api: ForgejoClient, ref: IssueRef, entries: readonly TimelineEntry[]): Promise<string[]> {
  const isTrusted = createTrustCheck(api, ref);
  const heads: string[] = [];
  for (const entry of entries) {
    if (entry.kind !== 'comment' || !LANDED_LINE.test(firstLine(entry.body))) continue;
    const head = fieldOf(entry.body, 'Reviewed head');
    if (head !== undefined && (await isTrusted(entry.author))) heads.push(head);
  }
  return heads;
}

export function hasReleasedRecord(history: IssueHistory, repository: RepositoryRef, tag: string): boolean {
  const landing = findNewestLanding(history, repository);
  return landing !== undefined && history.releases.some((release) => isSameRepository(release.repository, repository) && release.tag === tag && release.index > landing.index);
}

// Whether the history holds a proof of this environment after the newest landing, so the writer writes none twice.
// Only a trusted proof counts: on a public repository anybody can write "Proven on" before the writer does.
export function hasProvenRecord(history: IssueHistory, environment: string): boolean {
  const landing = newest(history.landings);
  return history.proofs.some((proof) => proof.environment === environment && (landing === undefined || proof.index > landing.index));
}
