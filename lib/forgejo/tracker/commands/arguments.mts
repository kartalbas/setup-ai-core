import { readFile } from 'node:fs/promises';
import { parseIssueNumber, parseRepository } from '../domain/issues.mts';
import type { IssueRef, RepositoryRef } from '../domain/issues.mts';
import { UsageError } from '../domain/refusals.mts';
import type { GitClient } from '../git/git.mts';

export type OptionKind = 'value' | 'repeat' | 'switch';

export interface ParsedArguments {
  readonly values: ReadonlyMap<string, string>;
  readonly lists: ReadonlyMap<string, readonly string[]>;
  readonly switches: ReadonlySet<string>;
  readonly positionals: readonly string[];
}

// Options are separated from their values (`--title TEXT`). An option that is not in the spec, a
// value that is missing and a value given twice are errors.
export function parseArguments(args: readonly string[], spec: Readonly<Record<string, OptionKind>>): ParsedArguments {
  const values = new Map<string, string>();
  const lists = new Map<string, string[]>();
  const switches = new Set<string>();
  const positionals: string[] = [];
  for (let index = 0; index < args.length; index++) {
    const argument = args[index] ?? '';
    if (argument === '--') {
      positionals.push(...args.slice(index + 1));
      break;
    }
    if (!argument.startsWith('--')) {
      positionals.push(argument);
      continue;
    }
    const kind = spec[argument];
    if (kind === undefined) throw new UsageError(`unknown option '${argument}'`);
    if (kind === 'switch') {
      switches.add(argument);
      continue;
    }
    const value = args[index + 1];
    if (value === undefined || value.startsWith('--')) throw new UsageError(`${argument} needs a value`);
    index++;
    if (kind === 'value') {
      if (values.has(argument)) throw new UsageError(`${argument} is given twice`);
      values.set(argument, value);
    } else {
      lists.set(argument, [...(lists.get(argument) ?? []), value]);
    }
  }
  return { values, lists, switches, positionals };
}

export function requireValue(parsed: ParsedArguments, option: string): string {
  const value = parsed.values.get(option);
  if (value === undefined || value === '') throw new UsageError(`${option} is required`);
  return value;
}

export function listOf(parsed: ParsedArguments, option: string): readonly string[] {
  return parsed.lists.get(option) ?? [];
}

export async function readTextFile(path: string): Promise<string> {
  try {
    return await readFile(path, 'utf8');
  } catch {
    throw new UsageError(`cannot read the file ${path}`);
  }
}

// `[OWNER/REPO]` first, or the repository of the origin of the current clone.
export async function takeRepository(positionals: readonly string[], git: GitClient, cwd: string): Promise<{ repository: RepositoryRef; rest: readonly string[] }> {
  const first = positionals[0];
  if (first !== undefined && first.includes('/')) return { repository: parseRepository(first), rest: positionals.slice(1) };
  const origin = await git.originRepository(cwd);
  return { repository: origin, rest: positionals };
}

export async function takeIssues(positionals: readonly string[], git: GitClient, cwd: string, usage: string): Promise<{ refs: IssueRef[]; rest: readonly string[] }> {
  const { repository, rest } = await takeRepository(positionals, git, cwd);
  const numbers: string[] = [];
  let index = 0;
  while (index < rest.length && /^[0-9]/.test(rest[index] ?? '')) numbers.push(rest[index++] ?? '');
  if (numbers.length === 0) throw new UsageError(usage);
  return { refs: numbers.map((number) => ({ ...repository, number: parseIssueNumber(number) })), rest: rest.slice(index) };
}

export async function takeIssue(positionals: readonly string[], git: GitClient, cwd: string, usage: string): Promise<{ ref: IssueRef; rest: readonly string[] }> {
  const { repository, rest } = await takeRepository(positionals, git, cwd);
  const number = rest[0];
  if (number === undefined) throw new UsageError(usage);
  return { ref: { ...repository, number: parseIssueNumber(number) }, rest: rest.slice(1) };
}

// `OWNER/REPO#NUMBER`, the way an issue of another repository is named.
export function parseIssueReference(text: string): IssueRef {
  const match = /^([^#]+)#([0-9]+)$/.exec(text);
  if (match?.[1] === undefined || match[2] === undefined) throw new UsageError(`${text} is not OWNER/REPO#NUMBER`);
  return { ...parseRepository(match[1]), number: parseIssueNumber(match[2]) };
}

// As takeIssue, but where no repository is named, the issue of a branch that start-issue marked as the issue of
// another repository (branch.<name>.issueRepository) is that repository's.
export async function takeIssueOfWorktree(positionals: readonly string[], git: GitClient, cwd: string, usage: string): Promise<{ ref: IssueRef; rest: readonly string[] }> {
  const first = positionals[0];
  const branch = first !== undefined && first.includes('/') ? undefined : await git.currentBranch(cwd);
  const recorded = branch === undefined ? undefined : await git.getConfig(cwd, `branch.${branch}.issueRepository`);
  if (recorded === undefined) return takeIssue(positionals, git, cwd, usage);
  const number = positionals[0];
  if (number === undefined) throw new UsageError(usage);
  return { ref: { ...parseRepository(recorded), number: parseIssueNumber(number) }, rest: positionals.slice(1) };
}

export function refuseExtra(rest: readonly string[], usage: string): void {
  if (rest.length > 0) throw new UsageError(`unexpected '${rest[0] ?? ''}'. ${usage}`);
}
