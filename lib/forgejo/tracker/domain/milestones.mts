import { ContractError, NotFoundError, segment } from '../api/client.mts';
import type { ForgejoClient } from '../api/client.mts';
import { milestoneShape, tagShape } from '../api/shapes.mts';
import type { CreateMilestoneBody } from '../api/shapes.mts';
import { editIssue, formatIssue, formatRepository, repositoryPath } from './issues.mts';
import type { IssueRef, RepositoryRef } from './issues.mts';

export interface ReleaseMilestone {
  readonly id: number;
  readonly title: string;
}

// Whether the repository has the tag. A repository or a tag that is not there is the same answer, and
// any other failure is passed on, so a refused read is never taken for a missing tag.
export async function tagExists(api: ForgejoClient, repository: RepositoryRef, tag: string): Promise<boolean> {
  const name = `read the tag ${tag} of ${formatRepository(repository)}`;
  try {
    const found = await api.call({ name, method: 'GET', path: `${repositoryPath(repository)}/tags/${segment(tag)}`, success: 200, read: tagShape.type.read });
    if (found.name !== tag) throw new ContractError(name, `Forgejo answered the tag ${found.name}`);
    return true;
  } catch (error) {
    if (error instanceof NotFoundError) return false;
    throw error;
  }
}

// Every milestone of the repository, open or closed, with the title exactly as given. The name filter of
// the list is not trusted to match whole titles, so the list is read to its end and filtered here.
export async function findReleaseMilestone(api: ForgejoClient, repository: RepositoryRef, tag: string): Promise<ReleaseMilestone | undefined> {
  const all = await api.callAll({ name: `list the milestones of ${formatRepository(repository)}`, path: `${repositoryPath(repository)}/milestones`, query: { state: 'all' }, readItem: milestoneShape.type.read });
  const matching = all.filter((milestone) => milestone.title === tag);
  if (matching.length > 1) throw new ContractError(`find the milestone ${tag} of ${formatRepository(repository)}`, `${matching.length} milestones carry this title, and which one is the release is not for this command to guess`);
  const found = matching[0];
  return found === undefined ? undefined : { id: found.id, title: found.title };
}

// The milestone named by the tag in this repository, made when it is not there. A milestone belongs to one
// repository, so the one of another repository is never reused.
export async function ensureReleaseMilestone(api: ForgejoClient, repository: RepositoryRef, tag: string): Promise<{ readonly milestone: ReleaseMilestone; readonly created: boolean }> {
  const existing = await findReleaseMilestone(api, repository, tag);
  if (existing !== undefined) return { milestone: existing, created: false };
  const body: CreateMilestoneBody = { title: tag };
  const made = await api.call({ name: `create the milestone ${tag} of ${formatRepository(repository)}`, method: 'POST', path: `${repositoryPath(repository)}/milestones`, body, success: 201, read: milestoneShape.type.read });
  if (made.title !== tag) throw new ContractError(`create the milestone ${tag} of ${formatRepository(repository)}`, `Forgejo made the milestone ${made.title}`);
  return { milestone: { id: made.id, title: made.title }, created: true };
}

// Sets the milestone on the issue; the answer is read back, so a milestone Forgejo did not set is a failure.
export async function setReleaseMilestone(api: ForgejoClient, ref: IssueRef, milestone: ReleaseMilestone): Promise<void> {
  const issue = await editIssue(api, ref, { milestone: milestone.id });
  if (issue.milestone?.id !== milestone.id) {
    throw new ContractError(`set the milestone ${milestone.title} on issue ${formatIssue(ref)}`, `Forgejo kept ${issue.milestone?.title ?? 'no milestone'}`);
  }
}
