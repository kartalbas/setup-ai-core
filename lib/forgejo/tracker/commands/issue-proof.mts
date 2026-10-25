import { dirname, join } from 'node:path';
import { addComment, afterStep, editIssue, formatIssue, formatRepository, getIssue, isSameRepository } from '../domain/issues.mts';
import type { RepositoryRef } from '../domain/issues.mts';
import { replaceFamilyLabel, statusLabel } from '../domain/labels.mts';
import { checkPublicText } from '../domain/public-text.mts';
import { PreconditionError, UsageError } from '../domain/refusals.mts';
import { composeProvenRecord, environmentsWith, findNewestLanding, hasProvenRecord, isHarnessLayer, landedEnvironments, listMissingDelivery, readIssueHistory, readTimeline } from '../domain/workflow.mts';
import type { CommandDeliveryCheck, LandingFact } from '../domain/workflow.mts';
import { GitError } from '../git/git.mts';
import { parseArguments, readTextFile, refuseExtra, requireValue, takeIssue } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: issue-proof [OWNER/REPO] NUMBER --environment ENV --body-file PATH';
export const help = `${USAGE}

Writes the record "Proven on ENV:" with the evidence of PATH, sets status/done and closes the issue as completed.
It refuses unless the issue records a landing and, for every repository the landing names, a release that came
after it, all of an account with write permission and after the last reopening for new work. A reopening keeps earlier
landings and releases if its first status label added by an account with write permission is status/testing; any other
status or no added status label requires delivery again. Every reopening requires a new proof. Where a repository's
own LIVE_TAGS names ENV with the pattern landed, its landing is its delivery and needs no release. Where it
names ENV with the pattern command, the reader of LIVE_RELEASE_COMMAND in its checkout answers the newest
completed delivery, and the landing is delivered once that delivery's commit holds the newest landed commit; no
delivery, a reader's error or a delivery without the landing refuses and says why. Another repository's
LIVE_TAGS is read from its checkout beside this clone's main checkout; a missing checkout is refused.
A landing in a harness layer, a repository named <prefix>-ai-core, also needs no release: init deploys it from
its default branch. Text with a literal email address is refused for a public repository. Run again after a
failure, it writes only what is missing.`;

const ENVIRONMENT = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

// The landing is delivered where the commit of the newest completed delivery holds the newest landed commit.
async function findMissingCommandDelivery(context: CommandContext, checkout: string, repository: RepositoryRef, environment: string, landing: LandingFact | undefined): Promise<string | undefined> {
  const name = formatRepository(repository);
  if (landing?.commit === undefined) return `the "Landed on" record of ${name} names no landed commit, so its delivery on ${environment} cannot be compared with it`;
  const read = await context.harness.readLiveRelease(checkout, name, environment);
  let answer: { delivered?: { commit: string; releasedAt: string; source: string } | null } | undefined;
  try {
    answer = read.succeeded ? JSON.parse(read.output) : undefined;
  } catch {
    answer = undefined;
  }
  if (answer?.delivered === undefined) return `the delivery of ${name} on ${environment} could not be read: ${read.output}`;
  if (answer.delivered === null) return `the reader of ${name} found no completed delivery on ${environment}`;
  const delivered = answer.delivered;
  try {
    if (await context.git.isAncestor(checkout, landing.commit, delivered.commit)) return undefined;
  } catch (error) {
    if (!(error instanceof GitError)) throw error;
    return `${checkout} has no landed commit ${landing.commit} of ${name}: fetch it, then prove again`;
  }
  return `${name} was last delivered on ${environment} by ${delivered.source} at ${delivered.releasedAt}, which does not hold its landed commit ${landing.commit}`;
}

async function requireCheckoutOf(context: CommandContext, checkout: string, repository: RepositoryRef, name: string): Promise<void> {
  const refusal = `${name} is not delivered, so nothing is proven: ${checkout} is not a checkout of ${formatRepository(repository)}`;
  let origin: RepositoryRef;
  try {
    origin = await context.git.originRepository(checkout);
  } catch (error) {
    throw new PreconditionError(`${refusal}: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (!isSameRepository(origin, repository)) throw new PreconditionError(`${refusal}, its origin is ${formatRepository(origin)}`);
}

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
  const clone = await context.git.originRepository(context.cwd);
  const mainCheckout = await context.git.mainCheckout(context.cwd);
  const projectFolder = dirname(mainCheckout);
  const landingIsDelivery: RepositoryRef[] = [];
  const commandDeliveries: CommandDeliveryCheck[] = [];
  const seen = new Set<string>();
  for (const { repository } of history.landings) {
    const key = formatRepository(repository).toLowerCase();
    if (seen.has(key) || isHarnessLayer(repository)) continue;
    seen.add(key);
    let liveTags = context.settings.liveTags;
    let checkout = mainCheckout;
    if (!isSameRepository(repository, clone)) {
      checkout = join(projectFolder, repository.repo);
      await requireCheckoutOf(context, checkout, repository, name);
      const read = await context.harness.readLiveTags(checkout);
      if (!read.succeeded) throw new PreconditionError(`${name} is not delivered, so nothing is proven: could not read LIVE_TAGS in ${checkout}: ${read.output}`);
      liveTags = read.output;
    }
    if (landedEnvironments(liveTags).includes(environment)) landingIsDelivery.push(repository);
    else if (environmentsWith(liveTags, 'command').includes(environment)) {
      commandDeliveries.push({ repository, missing: await findMissingCommandDelivery(context, checkout, repository, environment, findNewestLanding(history, repository)) });
    }
  }
  const missing = listMissingDelivery(history, landingIsDelivery, commandDeliveries);
  if (missing.length > 0) throw new PreconditionError(`${name} is not delivered, so nothing is proven: ${missing.join('; ')}`);
  await checkPublicText(api, 'issue-proof', ref, evidence);

  if (!hasProvenRecord(history, environment)) await addComment(api, ref, composeProvenRecord(environment, evidence));
  await afterStep(`close issue ${name} as completed`, `wrote the record "Proven on ${environment}:"`, async () => {
    await replaceFamilyLabel(api, ref, issue, statusLabel('done'));
    await editIssue(api, ref, { state: 'closed' });
  });
  return succeeded([`${name} proven on ${environment}; ${statusLabel('done')}, closed as completed`]);
}
