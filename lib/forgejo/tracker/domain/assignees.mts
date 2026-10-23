import { readFile } from 'node:fs/promises';
import { formatRepository } from './issues.mts';
import type { RepositoryRef } from './issues.mts';
import { UsageError } from './refusals.mts';

// assignees.tsv, read as lib/board.sh reads it: one row per repository, "OWNER/REPO<TAB>login", exactly one tab,
// no space at the edge of a column, a comment opens with # in column one. Nothing is trimmed and no row is
// skipped, so a row that is wrong stops the run and is named.
export function parseAssigneeMap(text: string, source: string): ReadonlyMap<string, string> {
  const logins = new Map<string, string>();
  text.split('\n').forEach((line, index) => {
    if (line === '' || line.startsWith('#')) return;
    const where = `${source}:${index + 1}`;
    const columns = line.split('\t');
    const [repository = '', login = ''] = columns;
    if (columns.length !== 2 || repository === '' || login === '') throw new UsageError(`${where} is not 'repo<TAB>login': ${line}`);
    if ([repository, login].some((column) => column.startsWith(' ') || column.endsWith(' '))) {
      throw new UsageError(`${where} has a space at the edge of a column, and the format allows none: '${repository}' '${login}'`);
    }
    if (logins.has(repository)) throw new UsageError(`${source} lists ${repository} twice - which one is right is not for a script to guess`);
    logins.set(repository, login);
  });
  return logins;
}

// The login the file names for the repository, or nothing where it names none.
export async function findOwnerLogin(file: string | undefined, repository: RepositoryRef): Promise<string | undefined> {
  if (file === undefined) throw new UsageError('this command needs the assignees file: run it through ai-core');
  let text: string;
  try {
    text = await readFile(file, 'utf8');
  } catch {
    throw new UsageError(`cannot read the assignee map ${file}`);
  }
  return parseAssigneeMap(text, file).get(formatRepository(repository));
}
