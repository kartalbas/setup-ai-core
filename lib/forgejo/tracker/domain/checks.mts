import { ContractError, segment } from '../api/client.mts';
import type { ForgejoClient } from '../api/client.mts';
import { combinedStatusShape, repositoryShape } from '../api/shapes.mts';
import { formatRepository, repositoryPath } from './issues.mts';
import type { RepositoryRef } from './issues.mts';

// The checks of a commit, as the combined commit status of Forgejo reports them. A repository that is public
// lands only on the green checks of the commit that lands; a private one rests on its push gate.

export type Visibility = 'public' | 'private';
export type ChecksState = 'green' | 'red' | 'pending';

// Public or private, and an error where Forgejo does not say: a visibility that cannot be read is never guessed.
export async function readVisibility(api: ForgejoClient, repository: RepositoryRef): Promise<Visibility> {
  const found = await api.call({ name: `read the visibility of ${formatRepository(repository)}`, method: 'GET', path: repositoryPath(repository), success: 200, read: repositoryShape.type.read });
  return found.private ? 'private' : 'public';
}

// Forgejo answers an empty object while no check has reported on the commit, which is pending and not green.
export async function readChecks(api: ForgejoClient, repository: RepositoryRef, commit: string): Promise<ChecksState> {
  const name = `read the checks of ${commit.slice(0, 7)} in ${formatRepository(repository)}`;
  const found = await api.call({ name, method: 'GET', path: `${repositoryPath(repository)}/commits/${segment(commit)}/status`, success: 200, read: combinedStatusShape.type.read });
  if (found.total_count === undefined || found.total_count === 0) return 'pending';
  switch (found.state) {
    case 'success':
      return 'green';
    case 'error':
    case 'failure':
    case 'warning':
      return 'red';
    case 'pending':
      return 'pending';
    default:
      throw new ContractError(name, `the state '${found.state ?? 'none'}' is none of success, pending, warning, failure or error`);
  }
}

export interface Waiting {
  readonly pollMilliseconds: number;
  readonly limitMilliseconds: number;
}

export type ChecksOutcome = 'green' | 'red' | 'unfinished';

// Asks at once and then every poll interval, until the checks are green or red or the limit has passed.
export async function waitForChecks(api: ForgejoClient, repository: RepositoryRef, commit: string, waiting: Waiting, announce: () => void): Promise<ChecksOutcome> {
  const started = Date.now();
  let announced = false;
  for (;;) {
    const state = await readChecks(api, repository, commit);
    if (state !== 'pending') return state;
    if (Date.now() - started >= waiting.limitMilliseconds) return 'unfinished';
    if (!announced) {
      announce();
      announced = true;
    }
    await new Promise<void>((resolve) => setTimeout(resolve, waiting.pollMilliseconds));
  }
}
