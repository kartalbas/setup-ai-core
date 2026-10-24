import { addComment, applyInOrder, formatIssue, formatRepository, getIssue, isSameRepository, parseIssueNumber, parseRepository } from '../domain/issues.mts';
import type { IssueRef, RepositoryRef } from '../domain/issues.mts';
import { ensureReleaseMilestone, setReleaseMilestone, tagExists } from '../domain/milestones.mts';
import { PreconditionError, UsageError } from '../domain/refusals.mts';
import { composeReleasedRecord, hasReleasedRecord, readIssueHistory, readTimeline } from '../domain/workflow.mts';
import { parseArguments, parseIssueReference, requireValue } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: issue-release --repo OWNER/REPO --tag TAG ISSUE...  (ISSUE: NUMBER of --repo, or OWNER/REPO#NUMBER)';
export const help = `${USAGE}

Records that the release TAG of --repo carries the work of each issue. TAG must exist in --repo. For an issue of
--repo, the milestone named TAG of that repository (made if it is not there) is set on it. If a newer landing
follows that milestone, it also writes the comment "Released in OWNER/REPO TAG:". For an issue of another
repository it writes that comment instead, because a milestone belongs to one repository. It publishes nothing
and creates no tag. Run again, it writes only what is missing.`;

function parseIssues(texts: readonly string[], repository: RepositoryRef): IssueRef[] {
  if (texts.length === 0) throw new UsageError(USAGE);
  return texts.map((text) => (text.includes('#') ? parseIssueReference(text) : { ...repository, number: parseIssueNumber(text) }));
}

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, { '--repo': 'value', '--tag': 'value' });
  const repository = parseRepository(requireValue(parsed, '--repo'));
  const tag = requireValue(parsed, '--tag');
  const refs = parseIssues(parsed.positionals, repository);
  const api = context.api();
  if (!(await tagExists(api, repository, tag))) throw new PreconditionError(`${formatRepository(repository)} has no tag ${tag}, so nothing is released: create the tag first`);

  const lines: string[] = [];
  const own = refs.filter((ref) => isSameRepository(ref, repository));
  const milestone = own.length === 0 ? undefined : await ensureReleaseMilestone(api, repository, tag);
  if (milestone?.created === true) lines.push(`created the milestone ${tag} in ${formatRepository(repository)}`);
  await applyInOrder('record the release', refs, formatIssue, async (ref) => {
    if (milestone !== undefined && isSameRepository(ref, repository)) {
      const issue = await getIssue(api, ref);
      if (issue.milestone?.id === milestone.milestone.id) {
        const history = await readIssueHistory(api, issue, await readTimeline(api, ref));
        const needsReleaseRecord = history.landings.some((landing) => isSameRepository(landing.repository, repository)
          && !history.releases.some((release) => isSameRepository(release.repository, repository) && release.tag === tag && release.at > landing.at));
        if (!needsReleaseRecord) {
          lines.push(`${formatIssue(ref)} has the milestone ${tag} already`);
          return;
        }
      } else {
        await setReleaseMilestone(api, ref, milestone.milestone);
        lines.push(`${formatIssue(ref)} -> milestone ${tag}${issue.milestone === undefined ? '' : ` (it was ${issue.milestone.title})`}`);
        return;
      }
    } else if (hasReleasedRecord(await readTimeline(api, ref), repository, tag)) {
      lines.push(`${formatIssue(ref)} records the release ${tag} of ${formatRepository(repository)} already`);
      return;
    }
    await addComment(api, ref, composeReleasedRecord(repository, tag));
    lines.push(`${formatIssue(ref)} <- "Released in ${formatRepository(repository)} ${tag}"`);
  });
  return succeeded(lines);
}
