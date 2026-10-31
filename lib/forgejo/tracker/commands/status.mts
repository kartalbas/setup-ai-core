import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { formatRepository, parseRepository, parseStateFilter, searchIssues } from '../domain/issues.mts';
import type { Issue, RepositoryRef } from '../domain/issues.mts';
import { canonicalLabelName, PRIORITY_VALUES, STATUS_VALUES, valueOfFamily } from '../domain/labels.mts';
import { PreconditionError, UsageError } from '../domain/refusals.mts';
import { findCurrentProof, holdsNoLandedRecord, readIssueHistory, readTimeline } from '../domain/workflow.mts';
import { listOf, parseArguments } from './arguments.mts';
import { lines } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: status [OWNER/REPO...] [--state open|closed|all] [--label NAME...] [--json] | status [OWNER/REPO...] --tokens';
export const help = `${USAGE}

Lists the issues the tracker records, every page of them, per owner. Without a repository it takes the
repositories of the clones beside the current checkout. --label may be given more than once and an issue must
carry all of them. The list is what the tracker records: it observes no deployment.

The page ends with the TESTING block of bin/status.sh over the listed open issues that carry status/testing, one line
each: 🔴 where a release of the first environment of LIVE_TAGS carries its work and no proof follows it, ⏸ where no such
release does yet, 🟢 where its proof is written. The landing and the proof are read from the issue's timeline as
issue-close reads them, the releases from the clones. An issue whose timeline could not be read is that issue's ❓ line.
Unlike the page of a board, this block does not make the command exit 1 for such a line.

--tokens prints the page of bin/status.sh --tokens over every issue of those repositories, open and closed: the
windows of the tool of the session (Claude, Codex or agy; a figure only Claude Code's records give says there is
no source for another tool), the issues closed in the last 24 hours, what an issue costs of a window, the tokens.
It takes no --state, --label or --json. Forgejo has no board and no epics, so the page counts the issues the
status/ labels name, and it holds no tally of reviews.`;

// What the tracker holds of one card in testing, as lib/status.mjs reads it (lib/status-testing.sh adds what only a clone answers)
interface TestingRecord {
  readonly repository: string;
  readonly number: number;
  readonly createdAt: string;
  readonly context: 'read' | 'failed';
  readonly reason: string;
  readonly landing: { readonly repository: string; readonly commit: string; readonly createdAt: string } | null;
  readonly proofs: readonly { readonly environment: string; readonly createdAt: string }[];
}

interface Row {
  readonly repository: string;
  readonly number: number;
  readonly title: string;
  readonly state: string;
  readonly status: string | null;
  readonly priority: string | null;
  readonly closedAt: string | null;
  readonly labels: readonly string[];
  readonly assignees: readonly string[];
  readonly url: string;
}

function rank(values: readonly string[], value: string | null): number {
  const index = value === null ? -1 : values.map((entry) => entry.toLowerCase()).indexOf(value);
  return index < 0 ? values.length : index;
}

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, { '--state': 'value', '--label': 'repeat', '--json': 'switch', '--tokens': 'switch' });
  const tokens = parsed.switches.has('--tokens');
  if (tokens && (parsed.values.has('--state') || listOf(parsed, '--label').length > 0 || parsed.switches.has('--json'))) {
    throw new UsageError('--tokens counts every issue of the repositories and prints a page: it takes no --state, --label or --json');
  }
  const state = tokens ? 'all' : parseStateFilter(parsed.values.get('--state') ?? 'open');
  const wantedLabels = listOf(parsed, '--label').map(canonicalLabelName);
  const named: RepositoryRef[] = parsed.positionals.map(parseRepository);
  const repositories = named.length > 0 ? named : await context.git.listCloneOrigins(context.cwd);
  if (repositories.length === 0) throw new UsageError('no repository: name one, or run it beside the clones of a project');
  const keep = new Set(repositories.map((repository) => formatRepository(repository).toLowerCase()));
  const owners = [...new Set(repositories.map((repository) => repository.owner))];

  const api = context.api();
  const rows: Row[] = [];
  const testingIssues: Issue[] = [];
  for (const owner of owners) {
    for (const issue of await searchIssues(api, owner, state)) {
      const name = formatRepository(issue.repository);
      if (!keep.has(name.toLowerCase())) continue;
      if (!wantedLabels.every((label) => issue.labels.includes(label))) continue;
      rows.push({
        repository: name,
        number: issue.ref.number,
        title: issue.title,
        state: issue.state,
        status: valueOfFamily(issue.labels, 'status'),
        priority: valueOfFamily(issue.labels, 'priority'),
        closedAt: issue.closedAt ?? null,
        labels: issue.labels,
        assignees: issue.assignees,
        url: issue.url,
      });
      if (issue.state === 'open' && valueOfFamily(issue.labels, 'status') === 'testing') testingIssues.push(issue);
    }
  }
  rows.sort(
    (a, b) =>
      a.repository.localeCompare(b.repository) ||
      rank(STATUS_VALUES, a.status) - rank(STATUS_VALUES, b.status) ||
      rank(PRIORITY_VALUES, a.priority) - rank(PRIORITY_VALUES, b.priority) ||
      a.number - b.number,
  );
  if (tokens) return tokensPage(rows, owners[0] ?? '', context);
  if (parsed.switches.has('--json')) return { stdout: lines(JSON.stringify(rows)), stderr: '', exitCode: 0 };

  const text: string[] = [];
  let current = '';
  for (const row of rows) {
    if (row.repository !== current) {
      current = row.repository;
      text.push(current);
    }
    text.push(`  #${row.number} [${row.status ?? 'no status'}${row.priority === null ? '' : ` ${row.priority}`}${row.state === 'closed' ? ' closed' : ''}] ${row.title}`);
  }
  text.push(`${rows.length} issue${rows.length === 1 ? '' : 's'} as the tracker records them`);
  if (testingIssues.length > 0) text.push('', await testingPage(rows, testingIssues, owners[0] ?? '', context));
  return { stdout: lines(...text), stderr: '', exitCode: 0 };
}

// The newest landing record that lands all of the issue's work in its repository, and the proof that follows it as issue-close counts it
async function readTestingRecord(issue: Issue, context: CommandContext): Promise<TestingRecord> {
  const repository = formatRepository(issue.ref);
  const record = { repository, number: issue.ref.number, createdAt: issue.createdAt };
  try {
    const entries = await readTimeline(context.api(), issue.ref);
    const history = await readIssueHistory(context.api(), issue, entries);
    const landing = history.landings.filter((fact) => !fact.isPart && fact.commit !== undefined).reduce<(typeof history.landings)[number] | undefined>((newest, fact) => (newest === undefined || fact.index > newest.index ? fact : newest), undefined);
    const proof = findCurrentProof(history, holdsNoLandedRecord(entries));
    return {
      ...record,
      context: 'read',
      reason: '',
      landing: landing?.commit === undefined ? null : { repository: formatRepository(landing.repository), commit: landing.commit, createdAt: new Date(landing.at).toISOString() },
      proofs: proof === undefined ? [] : [{ environment: proof.environment, createdAt: new Date(proof.at).toISOString() }],
    };
  } catch (error) {
    const said = error instanceof Error ? error.message : String(error);
    return { ...record, context: 'failed', reason: said.split('\n').map((line) => line.trim()).find((line) => line !== '') ?? 'the tracker gave no reason', landing: null, proofs: [] };
  }
}

// The TESTING block: the records of the open issues in testing and the lines git answers for them
async function testingPage(rows: readonly Row[], testingIssues: readonly Issue[], owner: string, context: CommandContext): Promise<string> {
  const folder = await mkdtemp(join(tmpdir(), 'ai-core-status-'));
  try {
    const itemsFile = join(folder, 'items');
    const columnsFile = join(folder, 'columns');
    const testingFile = join(folder, 'testing');
    await writeFile(itemsFile, lines(...cardRows(rows)));
    await writeFile(columnsFile, lines(...STATUS_VALUES));
    const records: TestingRecord[] = [];
    for (const issue of testingIssues) records.push(await readTestingRecord(issue, context));
    await writeFile(testingFile, lines(...records.map((record) => JSON.stringify(record))));
    const outcome = await context.harness.readTestingPage(context.cwd, itemsFile, columnsFile, testingFile, `${owner}/forgejo`);
    if (!outcome.succeeded) throw new PreconditionError(`the testing block of status could not be made: ${outcome.output}`);
    return outcome.output;
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
}

// The rows as lib/status.mjs reads a card: the status/ label is the column, and an issue has no parent and no sub-issue.
function cardRows(rows: readonly Row[]): string[] {
  return rows.map((row) =>
    JSON.stringify({
      repo: row.repository,
      number: row.number,
      title: row.title,
      open: row.state === 'open',
      status: row.status ?? '-',
      priority: row.priority === null ? null : row.priority.toUpperCase(),
      parent: null,
      subs: 0,
      closedAt: row.closedAt,
    }),
  );
}

async function tokensPage(rows: readonly Row[], owner: string, context: CommandContext): Promise<CommandResult> {
  const folder = await mkdtemp(join(tmpdir(), 'ai-core-status-'));
  try {
    const itemsFile = join(folder, 'items');
    const columnsFile = join(folder, 'columns');
    await writeFile(itemsFile, lines(...cardRows(rows)));
    await writeFile(columnsFile, lines(...STATUS_VALUES));
    const outcome = await context.harness.readTokensPage(context.cwd, itemsFile, columnsFile, `${owner}/forgejo`);
    if (!outcome.succeeded) throw new PreconditionError(`the page of status --tokens could not be made: ${outcome.output}`);
    return { stdout: lines(outcome.output), stderr: '', exitCode: 0 };
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
}
