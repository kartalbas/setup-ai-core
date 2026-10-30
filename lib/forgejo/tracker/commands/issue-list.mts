import { formatIssue, formatRepository, isSameRepository, parseOwner, parseStateFilter, searchIssues } from '../domain/issues.mts';
import type { RepositoryRef } from '../domain/issues.mts';
import { valueOfFamily } from '../domain/labels.mts';
import { UsageError } from '../domain/refusals.mts';
import { parseArguments, refuseExtra, takeRepository } from './arguments.mts';
import type { ParsedArguments } from './arguments.mts';
import { lines } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: issue-list [OWNER/REPO | --owner ORG] [--state open|closed|all] [--search TEXT]';
export const help = `${USAGE}

Lists issues and changes nothing: one line each, OWNER/REPO#NUMBER, the status/ label, the priority and the title,
separated by tabs, with a dash where an issue has no status or no priority, in the order of repository and number.
Without OWNER/REPO it reads the repository the origin of this clone names; with --owner ORG it reads every repository
of that organisation or user. --state is open (the default), closed or all. --search TEXT keeps the issues in whose
title, body or comments Forgejo's search finds every word of TEXT, in any order.`;

function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

interface Scope {
  readonly owner: string;
  readonly repository: RepositoryRef | undefined;
}

async function scopeOf(parsed: ParsedArguments, context: CommandContext): Promise<Scope> {
  const ownerName = parsed.values.get('--owner');
  if (ownerName === undefined) {
    const { repository, rest } = await takeRepository(parsed.positionals, context.git, context.cwd);
    refuseExtra(rest, USAGE);
    return { owner: repository.owner, repository };
  }
  if (parsed.positionals.length > 0) throw new UsageError(`--owner and OWNER/REPO exclude each other. ${USAGE}`);
  return { owner: parseOwner(ownerName), repository: undefined };
}

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, { '--state': 'value', '--search': 'value', '--owner': 'value' });
  const state = parseStateFilter(parsed.values.get('--state') ?? 'open');
  const text = parsed.values.get('--search');
  if (text !== undefined && text.trim() === '') throw new UsageError('--search needs the words to look for');
  const { owner, repository } = await scopeOf(parsed, context);

  const found = await searchIssues(context.api(), owner, state, text);
  const rows = found
    .filter((issue) => repository === undefined || isSameRepository(issue.repository, repository))
    .map((issue) => ({
      repository: formatRepository(issue.repository),
      number: issue.ref.number,
      line: [formatIssue(issue.ref), valueOfFamily(issue.labels, 'status') ?? '-', valueOfFamily(issue.labels, 'priority')?.toUpperCase() ?? '-', issue.title].join('\t'),
    }))
    .sort((a, b) => compare(a.repository, b.repository) || a.number - b.number);
  return { stdout: lines(...rows.map((row) => row.line)), stderr: '', exitCode: 0 };
}
