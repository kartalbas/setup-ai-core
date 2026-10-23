import { addComment, afterStep, editIssue, formatIssue, getIssue } from '../domain/issues.mts';
import { replaceFamilyLabel, statusLabel } from '../domain/labels.mts';
import { checkPublicText } from '../domain/public-text.mts';
import { PreconditionError, UsageError } from '../domain/refusals.mts';
import { composeProvenRecord, hasProvenRecord, landedEnvironments, listMissingDelivery, readIssueHistory, readTimeline } from '../domain/workflow.mts';
import { parseArguments, readTextFile, refuseExtra, requireValue, takeIssue } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: issue-proof [OWNER/REPO] NUMBER --environment ENV --body-file PATH';
export const help = `${USAGE}

Writes the record "Proven on ENV:" with the evidence of PATH, sets status/done and closes the issue as completed.
It refuses unless the issue records a landing and, for every repository the landing names, a release that came
after it, all of an account with write permission and after the last reopening of the issue. Where LIVE_TAGS names
ENV with the pattern landed, the landing in this clone's repository is its delivery and needs no release. Text
with a literal email address is refused for a public repository. Run again after a failure, it writes only
what is missing.`;

const ENVIRONMENT = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, { '--environment': 'value', '--body-file': 'value' });
  const { ref, rest } = await takeIssue(parsed.positionals, context.git, context.cwd, USAGE);
  refuseExtra(rest, USAGE);
  const environment = requireValue(parsed, '--environment');
  if (!ENVIRONMENT.test(environment)) throw new UsageError(`--environment is '${environment}', and an environment is a word of letters, digits, dots, hyphens and underscores`);
  const evidence = await readTextFile(requireValue(parsed, '--body-file'));
  if (evidence.trim() === '') throw new UsageError('the evidence is empty: a proof says what was seen');

  const api = context.api();
  const issue = await getIssue(api, ref);
  const name = formatIssue(ref);
  if (issue.state !== 'open') throw new PreconditionError(`${name} is closed: reopen it with issue-reopen --status testing before it is proven again`);
  const entries = await readTimeline(api, ref);
  const history = await readIssueHistory(api, issue, entries);
  const landingIsDelivery = landedEnvironments(context.settings.liveTags).includes(environment) ? [await context.git.originRepository(context.cwd)] : [];
  const missing = listMissingDelivery(history, landingIsDelivery);
  if (missing.length > 0) throw new PreconditionError(`${name} is not delivered, so nothing is proven: ${missing.join('; ')}`);
  await checkPublicText(api, 'issue-proof', ref, evidence);

  const lastLanding = Math.max(...history.landings.map((landing) => landing.at));
  if (!hasProvenRecord(entries, environment, lastLanding)) await addComment(api, ref, composeProvenRecord(environment, evidence));
  await afterStep(`close issue ${name} as completed`, `wrote the record "Proven on ${environment}:"`, async () => {
    await replaceFamilyLabel(api, ref, issue, statusLabel('done'));
    await editIssue(api, ref, { state: 'closed' });
  });
  return succeeded([`${name} proven on ${environment}; ${statusLabel('done')}, closed as completed`]);
}
