import { formatRepository, parseRepository, searchIssues } from '../domain/issues.mts';
import type { RepositoryRef } from '../domain/issues.mts';
import { canonicalLabelName, PRIORITY_VALUES, STATUS_VALUES } from '../domain/labels.mts';
import { UsageError } from '../domain/refusals.mts';
import { listOf, parseArguments } from './arguments.mts';
import { lines } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: status [OWNER/REPO...] [--state open|closed|all] [--label NAME...] [--json]';
export const help = `${USAGE}

Lists the issues the tracker records, every page of them, per owner. Without a repository it takes the
repositories of the clones beside the current checkout. --label may be given more than once and an issue must
carry all of them. This is what the tracker records: it observes no deployment.`;

type State = 'open' | 'closed' | 'all';

interface Row {
  readonly repository: string;
  readonly number: number;
  readonly title: string;
  readonly state: string;
  readonly status: string | null;
  readonly priority: string | null;
  readonly labels: readonly string[];
  readonly assignees: readonly string[];
  readonly url: string;
}

function valueOfFamily(labels: readonly string[], family: string): string | null {
  const found = labels.find((label) => label.startsWith(`${family}/`));
  return found === undefined ? null : found.slice(family.length + 1);
}

function rank(values: readonly string[], value: string | null): number {
  const index = value === null ? -1 : values.map((entry) => entry.toLowerCase()).indexOf(value);
  return index < 0 ? values.length : index;
}

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, { '--state': 'value', '--label': 'repeat', '--json': 'switch' });
  const state = parsed.values.get('--state') ?? 'open';
  if (state !== 'open' && state !== 'closed' && state !== 'all') throw new UsageError(`--state must be open, closed or all, not '${state}'`);
  const wantedLabels = listOf(parsed, '--label').map(canonicalLabelName);
  const named: RepositoryRef[] = parsed.positionals.map(parseRepository);
  const repositories = named.length > 0 ? named : await context.git.listCloneOrigins(context.cwd);
  if (repositories.length === 0) throw new UsageError('no repository: name one, or run it beside the clones of a project');
  const keep = new Set(repositories.map((repository) => formatRepository(repository).toLowerCase()));
  const owners = [...new Set(repositories.map((repository) => repository.owner))];

  const api = context.api();
  const rows: Row[] = [];
  for (const owner of owners) {
    for (const issue of await searchIssues(api, owner, state as State)) {
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
        labels: issue.labels,
        assignees: issue.assignees,
        url: issue.url,
      });
    }
  }
  rows.sort(
    (a, b) =>
      a.repository.localeCompare(b.repository) ||
      rank(STATUS_VALUES, a.status) - rank(STATUS_VALUES, b.status) ||
      rank(PRIORITY_VALUES, a.priority) - rank(PRIORITY_VALUES, b.priority) ||
      a.number - b.number,
  );
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
  return { stdout: lines(...text), stderr: '', exitCode: 0 };
}
