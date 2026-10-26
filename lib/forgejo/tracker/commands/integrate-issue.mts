import { existsSync } from 'node:fs';
import { mkdir, mkdtemp } from 'node:fs/promises';
import { join } from 'node:path';
import type { ForgejoClient } from '../api/client.mts';
import { readVisibility, waitForChecks } from '../domain/checks.mts';
import { addComment, currentLogin, explainMissingAssignment, formatIssue, formatRepository, getIssue, isSameIssue, isSameRepository } from '../domain/issues.mts';
import type { Issue, IssueRef, RepositoryRef } from '../domain/issues.mts';
import { replaceFamilyLabel, statusLabel } from '../domain/labels.mts';
import { PartialCompletionError, PreconditionError, UsageError } from '../domain/refusals.mts';
import { composeLandedRecord, hasLandedRecord, readTimeline } from '../domain/workflow.mts';
import { GitError } from '../git/git.mts';
import type { GitClient } from '../git/git.mts';
import { listOf, parseArguments, parseIssueReference, refuseExtra, takeIssuesOfWorktree } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: integrate-issue [OWNER/REPO] NUMBER [NUMBER ...] --reviewed-by NAME [--reviewed-by NAME ...] --reviewed-head SHA [--reviewed-head SHA ...] [--also OWNER/REPO#NUMBER ...]';
export const help = `${USAGE}

Lands the reviewed branch of one issue on the default branch of origin: a merge commit that names the issue and
carries a "Reviewed-by: NAME" line for each reviewer, pushed through the push gate of the repository. Run it in
the worktree of the issue, on its branch, after the reviewer's GO. Given several numbers (the repository named, or
recorded on the branch, holds for all), it lands the issues of a package in one push, each in a merge commit of its
own, in the order given, with one --reviewed-head per number in the same order: the first issue's branch is the one
of the worktree, every other one is read as origin holds it (issue-NUMBER-*), and its tip must be its reviewed
head. Everything is merged in the same temporary or detached tree, the push gate and the checks run once, and a
conflict, in any issue, lands none of them. --also records the landing of the first issue on further issues. Where the push gate is the check, the merge
is made and pushed in that worktree, detached on origin/<default>, so the gate finds the tools installed there,
and the worktree is on its branch again afterwards, whether the push landed or was refused; a run stopped
before that leaves it detached, and its first line names the git switch that puts it back. The lines of git and
of the push gate show while the push runs. Where the checks of Forgejo are read, the merge is made in a
temporary worktree, where scripts/install.sh of the merged tree runs first if it has one, its lines shown, and
a failing install refuses the landing with nothing pushed. Then every issue it lands (each one given and each
--also) gets status/testing and the record "Landed on <branch>:" with the reviewed head, the landed commit and
the reviewers. It discovers no other issue from the history of Git.

It refuses, before anything is merged or pushed: an issue that is closed or not assigned to the signed-in
account, a worktree with changes (at most twenty named, and their count where there are more), a branch head
that is not --reviewed-head, a CI_GATE that is neither public nor none, an ignored file of the worktree that
origin/<default> tracks, which the landing would overwrite, and, at the push, a default branch that moved, a
red gate and, for a public repository under CI_GATE=public, checks that are red or unfinished. CI_GATE=public
pushes the merge commit to ci/integrate-<branch>, waits for its combined commit status and lands exactly that
commit; CI_GATE=none and a private repository land on the push gate alone. After the landing the default branch
of the main checkout is fast-forwarded where it is only behind; a checkout that cannot be is named, and the
landing stands.

When the work landed and a record could not be written, the exit status is 4 and the message says what is done.
Run the same command again: it sees that the reviewed head is on the default branch, merges and pushes nothing,
and writes only the records that are missing. It sets status/testing only on an issue whose record it writes in
that run; an issue that holds its record keeps its status, and the output says so. Of a list, either every reviewed
head is on the default branch already or none is: a run in which some are and others are not is refused, naming
each issue, and nothing is merged. That rerun goes in the worktree of the issue, on its branch, and,
once finish-issue removed the worktree, in the main checkout (give OWNER/REPO where the issue lives in another
repository): there it writes the records only for a landed commit whose subject ends with the name of the issue
in parentheses, as this command writes it, and otherwise it refuses and writes nothing.`;

const POLL_SECONDS = 20;
const WAIT_SECONDS = 1800;
// An untracked folder lists every file in it, which can be thousands of lines.
const SHOWN_CHANGES = 20;

function positiveSeconds(text: string | undefined, fallback: number, name: string): number {
  if (text === undefined) return fallback;
  const seconds = Number(text);
  if (!Number.isFinite(seconds) || seconds <= 0) throw new UsageError(`${name} is '${text}', and it must be a positive number of seconds`);
  return seconds;
}

function parseReviewers(reviewers: readonly string[]): string[] {
  if (reviewers.length === 0) throw new UsageError(`who reviewed the work? --reviewed-by names the reviewer whose GO this lands. ${USAGE}`);
  const unique: string[] = [];
  for (const reviewer of reviewers) {
    if (reviewer.trim() === '' || /[\r\n]/.test(reviewer)) throw new UsageError('--reviewed-by takes one line with a name in it');
    if (!unique.includes(reviewer)) unique.push(reviewer);
  }
  return unique;
}

// How a commit names the issue: `#N` in the repository the work lands in, `owner/repo#N` from another.
function issueName(ref: IssueRef, codeRepository: RepositoryRef): string {
  return isSameRepository(ref, codeRepository) ? `#${ref.number}` : `${formatRepository(ref)}#${ref.number}`;
}

// The subject the gate takes is 72 characters at most, so a long title gives way to the branch name, then to the number.
function mergeSubject(title: string, branch: string, ref: IssueRef, codeRepository: RepositoryRef): string {
  const name = issueName(ref, codeRepository);
  const fallback = `Merge issue-${ref.number} (${name})`;
  const candidates = [title.trim() === '' ? fallback : `${title.trim()} (${name})`, `Merge ${branch} (${name})`, fallback];
  return candidates.find((candidate) => candidate.length <= 72) ?? fallback;
}

// A refusal of Git (a conflict, a hook, a remote that moved) means nothing landed; other failures pass on as they are.
function refusal(error: unknown, what: string): unknown {
  return error instanceof GitError ? new PreconditionError(`nothing landed: ${what} (${error.message})`) : error;
}

// The receipt and the mark reach the Git children of the pushes of a landing, and no other process.
function landingEnvironment(receipt: string | undefined, mark: string): Record<string, string> {
  return receipt === undefined ? { AI_CORE_LANDING_MARK: mark } : { AI_CORE_LANDING_RECEIPT: receipt, AI_CORE_LANDING_MARK: mark };
}

// The push to the default branch was refused. What origin holds for the branch now says why: another tip than the one
// this landing fetched means another landing moved the branch first; this landing's own commit means the push reached
// origin though git failed. Anything else keeps the cause git gave.
async function judgeRefusedPush(git: GitClient, cwd: string, defaultBranch: string, fetched: string, merged: string, error: unknown): Promise<'landed' | unknown> {
  let tip: string | undefined;
  try {
    tip = await git.remoteBranchTip(cwd, defaultBranch);
  } catch (reading) {
    return refusal(error, `the push to ${defaultBranch} was refused; origin could not be read afterwards to tell whether ${defaultBranch} moved: ${reading instanceof Error ? reading.message : String(reading)}`);
  }
  if (tip === merged) return 'landed';
  if (tip !== undefined && tip !== fetched) {
    return new PreconditionError(`nothing landed: ${defaultBranch} moved on origin from ${fetched.slice(0, 7)} to ${tip.slice(0, 7)} after this landing fetched it, so another landing got there first and it was not overwritten; run this again, which merges onto the new ${defaultBranch}`);
  }
  return refusal(error, `the push to ${defaultBranch} was refused; nothing reached origin`);
}

// One issue of a landing: the branch it comes from, its reviewed head and the subject of its merge commit.
interface LandingUnit {
  readonly branch: string;
  readonly head: string;
  readonly subject: string;
}

interface Landing {
  // The merge commit of each unit, in the order given; the last one is what the push sends.
  readonly commits: string[];
  readonly lines: string[];
}

async function landReviewedHeads(context: CommandContext, api: ForgejoClient, input: {
  readonly units: readonly LandingUnit[];
  readonly defaultBranch: string;
  readonly trailers: readonly string[];
  readonly codeRepository: RepositoryRef;
  readonly number: number;
}): Promise<Landing> {
  const { git, cwd } = context;
  const { defaultBranch } = input;
  const branch = input.units[0]?.branch ?? '';
  const ciGate = (context.settings.ciGate ?? 'public').toLowerCase();
  if (ciGate !== 'public' && ciGate !== 'none') throw new PreconditionError(`nothing landed: CI_GATE is '${ciGate}' in the config.env of the project; it is public or none`);
  const lines: string[] = [];
  let checked = false;
  if (ciGate === 'public') {
    const visibility = await readVisibility(api, input.codeRepository);
    checked = visibility === 'public';
    lines.push(
      checked
        ? `checks: ${formatRepository(input.codeRepository)} is public and lands only on green checks`
        : `checks: ${formatRepository(input.codeRepository)} is private, its push gate is its check; the checks of Forgejo are not read`,
    );
  } else {
    lines.push('checks: CI_GATE is none, the push gate is the check; the checks of Forgejo are not read');
  }

  // Where the push gate is the check, the merge is made and pushed in the issue's own worktree, which holds the
  // tools the gate needs; where the checks of Forgejo are read, it is made in a temporary worktree.
  let tree = cwd;
  if (checked) {
    const container = await git.worktreeContainer(cwd);
    await mkdir(container, { recursive: true });
    tree = await mkdtemp(join(container, `integrate-${input.number}.`));
  }
  const notes: string[] = [];
  let landed: string[] | undefined;
  let failure: unknown;
  let receipt: string | undefined;
  let mark: string | undefined;
  try {
    if (checked) {
      const opened = await context.harness.openLandingCheck(cwd);
      if (!opened.succeeded) throw new PreconditionError(`nothing landed: the receipt of the checks of this landing could not be opened (${opened.output})`);
      receipt = opened.output;
      await git.addDetachedWorktree(cwd, tree, `refs/remotes/origin/${defaultBranch}`);
    } else {
      context.stderr(`landing: this worktree goes onto origin/${defaultBranch} for the merge and the push gate, and back to ${branch} when the push lands or is refused; if this run is stopped before that, git switch ${branch} puts it back\n`);
      try {
        await git.switchDetached(cwd, `refs/remotes/origin/${defaultBranch}`);
      } catch (error) {
        throw refusal(error, `this worktree could not be put on origin/${defaultBranch} for the merge`);
      }
    }
    const base = await git.resolveCommit(tree, 'HEAD');
    const commits: string[] = [];
    for (const unit of input.units) {
      try {
        commits.push(await git.merge(tree, unit.head, `${unit.subject}\n\n${input.trailers.join('\n')}`));
      } catch (error) {
        throw refusal(error, `${unit.branch} does not merge cleanly into origin/${defaultBranch}: bring origin/${defaultBranch} into the branch, get the review of the result, then run this again`);
      }
    }
    const merged = commits[commits.length - 1] ?? base;
    // The push gate lets only a harness landing update the default branch: this landing says so for exactly these pushes.
    const ciBranch = `ci/integrate-${branch}`;
    const marked = await context.harness.openLandingMark(tree, merged, [`refs/heads/${defaultBranch}`, ...(checked ? [`refs/heads/${ciBranch}`] : [])]);
    if (!marked.succeeded) throw new PreconditionError(`nothing landed: the mark of this landing could not be made (${marked.output})`);
    mark = marked.output;

    if (checked) {
      if (existsSync(join(tree, 'scripts', 'install.sh'))) {
        context.stderr(`installing: scripts/install.sh of the merged tree runs in ${tree}, so the gate's check finds what it needs\n`);
        const installed = await context.harness.installTools(tree, context.stderr);
        if (!installed.succeeded) throw new PreconditionError(`nothing landed: scripts/install.sh failed in the temporary worktree, nothing was pushed and the worktree of ${branch} is as it was (${installed.output.split('\n').join(' | ')})`);
      }
      const held = await git.remoteBranchTip(cwd, ciBranch);
      try {
        await git.pushWithLease(tree, merged, ciBranch, held, context.stderr, landingEnvironment(receipt, mark));
      } catch (error) {
        throw refusal(error, `the merge commit ${merged.slice(0, 7)} could not be pushed to ${ciBranch} for its checks`);
      }
      try {
        const waiting = {
          pollMilliseconds: positiveSeconds(context.settings.integratePollSeconds, POLL_SECONDS, 'AI_CORE_INTEGRATE_POLL') * 1000,
          limitMilliseconds: positiveSeconds(context.settings.integrateWaitSeconds, WAIT_SECONDS, 'AI_CORE_INTEGRATE_WAIT') * 1000,
        };
        const outcome = await waitForChecks(api, input.codeRepository, merged, waiting, () => lines.push(`waiting: the checks of ${merged.slice(0, 7)} on ${ciBranch}`));
        if (outcome === 'red') throw new PreconditionError(`nothing landed: the checks for ${merged} on ${ciBranch} are red, so nothing was pushed to ${defaultBranch}`);
        if (outcome === 'unfinished') throw new PreconditionError(`nothing landed: the checks for ${merged} on ${ciBranch} did not finish in ${waiting.limitMilliseconds / 1000} seconds; set AI_CORE_INTEGRATE_WAIT higher if the CI takes longer`);
        lines.push(`checks: green for ${merged.slice(0, 7)} on ${ciBranch}`);
        if (receipt !== undefined) {
          const completed = await context.harness.completeLandingCheck(receipt, merged, `refs/heads/${ciBranch}`);
          if (!completed.succeeded) lines.push(`note: the receipt of ${merged.slice(0, 7)} could not be completed, so the push to ${defaultBranch} runs scripts/check.sh again (${completed.output})`);
        }
      } finally {
        await git.deleteRemoteBranch(cwd, ciBranch, merged).catch((error: unknown) => {
          notes.push(`${ciBranch} could not be deleted on origin, delete it by hand: ${error instanceof Error ? error.message : String(error)}`);
        });
      }
    }

    await git.fetchBranch(cwd, defaultBranch);
    const now = await git.resolveCommit(cwd, `refs/remotes/origin/${defaultBranch}`);
    if (now !== base) throw new PreconditionError(`nothing landed: origin/${defaultBranch} moved from ${base} to ${now} while the merge was made; run this again`);
    try {
      await git.push(tree, merged, defaultBranch, context.stderr, landingEnvironment(receipt, mark));
    } catch (error) {
      const judged = await judgeRefusedPush(git, cwd, defaultBranch, now, merged, error);
      if (judged !== 'landed') throw judged;
      lines.push(`origin holds ${merged.slice(0, 7)} on ${defaultBranch} although git reported a failure: the landing went through`);
    }
    landed = commits;
  } catch (error) {
    failure = error;
  } finally {
    if (mark !== undefined) {
      await context.harness.closeLandingMark(mark).then((closed) => {
        if (!closed.succeeded) notes.push(`the mark ${mark} could not be removed: ${closed.output}`);
      });
    }
    if (receipt !== undefined) {
      await context.harness.closeLandingCheck(receipt).then((closed) => {
        if (!closed.succeeded) notes.push(`the receipt ${receipt} could not be removed: ${closed.output}`);
      });
    }
    if (checked) {
      await git.discardWorktree(cwd, tree).catch((error: unknown) => {
        notes.push(`the temporary worktree ${tree} could not be removed: ${error instanceof Error ? error.message : String(error)}`);
      });
    } else {
      await git.switchBranch(cwd, branch).then(
        () => {
          if (landed === undefined) notes.push(`this worktree is on ${branch}`);
        },
        (error: unknown) => {
          notes.push(`${branch} could not be checked out again, run git switch ${branch} before finish-issue: ${error instanceof Error ? error.message : String(error)}`);
        },
      );
    }
  }
  if (landed === undefined) {
    if (failure instanceof Error && notes.length > 0) failure.message = `${failure.message}. ${notes.join(' ')}`;
    throw failure;
  }
  return { commits: landed, lines: [...lines, ...notes] };
}

// The reviewed heads, one per issue of the list in the order given.
function parseReviewedHeads(heads: readonly string[], issueCount: number): string[] {
  if (heads.length === 0) throw new UsageError(`--reviewed-head is required. ${USAGE}`);
  if (heads.length !== issueCount) throw new UsageError(`--reviewed-head is given once for each issue, in the order of the issues: ${issueCount} issue(s) and ${heads.length} reviewed head(s). ${USAGE}`);
  for (const head of heads) {
    if (!/^[0-9a-fA-F]{7,64}$/.test(head)) throw new UsageError(`--reviewed-head must be a commit id of at least 7 hexadecimal digits, not '${head}'`);
  }
  return [...heads];
}

// An issue of the run: what is landed for it, where its work comes from, and the issue as the tracker holds it.
interface Unit {
  readonly ref: IssueRef;
  readonly headArgument: string;
  readonly reviewedHead: string | undefined;
  readonly isLanded: boolean;
  // Without --reviewed-head on the default branch: the branch the work is merged from.
  branch: string | undefined;
  landedAt: string | undefined;
}

async function describeUnits(context: CommandContext, refs: readonly IssueRef[], headArguments: readonly string[], defaultTip: string): Promise<Unit[]> {
  const { git, cwd } = context;
  const units: Unit[] = [];
  for (const [index, ref] of refs.entries()) {
    const headArgument = headArguments[index] ?? '';
    const reviewedHead = await git.resolveCommit(cwd, headArgument).catch((error: unknown) => {
      if (error instanceof GitError) return undefined;
      throw error;
    });
    const isLanded = reviewedHead !== undefined && (await git.isAncestor(cwd, reviewedHead, defaultTip));
    units.push({ ref, headArgument, reviewedHead, isLanded, branch: undefined, landedAt: undefined });
  }
  return units;
}

// The branch of an issue after the first, as origin holds it: the one branch issue-<number>-*, fetched, whose tip is
// the reviewed head.
async function findOriginBranch(context: CommandContext, unit: Unit): Promise<string> {
  const { git, cwd } = context;
  const names = await git.listRemoteBranchNames(cwd, [`issue-${unit.ref.number}`, `issue-${unit.ref.number}-*`]);
  const [name, ...others] = names;
  if (name === undefined) throw new PreconditionError(`origin has no branch issue-${unit.ref.number}-* of ${formatIssue(unit.ref)} to land: push the reviewed branch, then run this again`);
  if (others.length > 0) throw new PreconditionError(`origin has more than one branch for issue ${unit.ref.number}, and which one the reviewer read is not for this command to guess: ${names.join(' ')}`);
  await git.fetchBranch(cwd, name);
  return name;
}

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, { '--reviewed-by': 'repeat', '--reviewed-head': 'repeat', '--also': 'repeat' });
  const { refs: listed, rest } = await takeIssuesOfWorktree(parsed.positionals, context.git, context.cwd, USAGE);
  refuseExtra(rest, USAGE);
  const reviewers = parseReviewers(listOf(parsed, '--reviewed-by'));
  const headArguments = parseReviewedHeads(listOf(parsed, '--reviewed-head'), listed.length);
  const ref = listed[0];
  if (ref === undefined) throw new UsageError(USAGE);
  const alsoRefs: IssueRef[] = [];
  for (const text of listOf(parsed, '--also')) {
    const other = parseIssueReference(text);
    if (![...listed, ...alsoRefs].some((known) => isSameIssue(known, other))) alsoRefs.push(other);
  }

  const { git, cwd } = context;
  const codeRepository = await git.originRepository(cwd);
  const defaultBranch = await git.defaultBranch(cwd);
  await git.fetchBranch(cwd, defaultBranch);
  const defaultRef = `refs/remotes/origin/${defaultBranch}`;
  const defaultTip = await git.resolveCommit(cwd, defaultRef);
  const branch = await git.currentBranch(cwd);
  const issueBranch = branch !== undefined && new RegExp(`^issue-${ref.number}(-.*)?$`).test(branch) ? branch : undefined;
  const units = await describeUnits(context, listed, headArguments, defaultTip);
  // A reviewed head on origin/<default> is landed already, and only its records are missing; any other has to be merged from its branch.
  // Of a list either every head has landed or none has: the records of some and the merge of others are two runs.
  const landedUnits = units.filter((unit) => unit.isLanded);
  if (landedUnits.length > 0 && landedUnits.length < units.length) {
    const names = (selected: readonly Unit[]): string => selected.map((unit) => formatIssue(unit.ref)).join(', ');
    throw new PreconditionError(`nothing is merged or written: the reviewed heads of ${names(landedUnits)} are on origin/${defaultBranch} already and those of ${names(units.filter((unit) => !unit.isLanded))} are not; land the issues that have not landed in a run of their own, then run this again for the records`);
  }
  const first = units[0];
  if (first === undefined) throw new UsageError(USAGE);
  for (const [index, unit] of units.entries()) {
    if (unit.isLanded && unit.reviewedHead !== undefined) unit.landedAt = await git.findLandingCommit(cwd, unit.reviewedHead, defaultRef);
    else if (index === 0) {
      if (issueBranch === undefined) throw new PreconditionError(`this runs in the worktree of issue ${ref.number}, on its branch issue-${ref.number}-*; here ${branch ?? 'no branch'} is checked out`);
      unit.branch = issueBranch;
    } else unit.branch = await findOriginBranch(context, unit);
  }
  if (issueBranch !== undefined) {
    const changes = await git.listChanges(cwd);
    if (changes.length > 0) {
      const shown = changes.length > SHOWN_CHANGES ? [...changes.slice(0, SHOWN_CHANGES), `and ${changes.length - SHOWN_CHANGES} more, ${changes.length} in all`] : changes;
      throw new PreconditionError(`the worktree has changes: commit them for the review, or put them aside, then run this again\n${shown.join('\n')}`);
    }
  }
  // Without the branch of the issue to tie the landed head to the issue (the worktree is gone, or was cut again), the
  // commit that landed it must name the issue, as this command writes it.
  for (const [index, unit] of units.entries()) {
    if (unit.landedAt === undefined || unit.reviewedHead === undefined) continue;
    const headIsReviewed = index === 0 && issueBranch !== undefined && (await git.resolveCommit(cwd, 'HEAD')) === unit.reviewedHead;
    const name = issueName(unit.ref, codeRepository);
    if (!headIsReviewed && !(await git.getSubject(cwd, unit.landedAt)).endsWith(`(${name})`)) {
      throw new PreconditionError(
        `nothing is written: ${unit.reviewedHead} is on origin/${defaultBranch}, but in the commit ${unit.landedAt.slice(0, 7)}, whose subject does not end with (${name}), so it is not shown to be the work of ${formatIssue(unit.ref)}; ` +
          `run the same command in the worktree of the issue, on ${unit.reviewedHead.slice(0, 7)}`,
      );
    }
  }

  const api = context.api();
  const login = await currentLogin(api);
  const read: Issue[] = [];
  for (const issueRef of [...listed, ...alsoRefs]) {
    const issue = await getIssue(api, issueRef);
    if (issue.state !== 'open') throw new PreconditionError(`${formatIssue(issueRef)} is closed: work lands on an open issue`);
    const unassigned = explainMissingAssignment(issue, login);
    if (unassigned !== undefined) throw new PreconditionError(unassigned);
    read.push(issue);
  }

  for (const unit of units) {
    if (unit.reviewedHead === undefined) throw new PreconditionError(`--reviewed-head ${unit.headArgument} is no commit of this clone`);
  }
  const heads: string[] = [];
  for (const [index, unit] of units.entries()) {
    let head = unit.reviewedHead ?? '';
    if (unit.branch !== undefined && !unit.isLanded) {
      head = await git.resolveCommit(cwd, index === 0 ? 'HEAD' : `refs/remotes/origin/${unit.branch}`);
      if (head !== unit.reviewedHead) {
        throw new PreconditionError(`nothing landed: the head of ${index === 0 ? unit.branch : `origin/${unit.branch}`} is ${head}, not the reviewed head ${unit.reviewedHead ?? ''}; the branch changed after the review`);
      }
    }
    heads.push(head);
  }

  const lines: string[] = [];
  const warnings: string[] = [];
  let landedCommits: string[];
  let landedNow = false;
  if (first.landedAt !== undefined) {
    landedCommits = units.map((unit) => unit.landedAt ?? '');
    for (const [index, unit] of units.entries()) {
      lines.push(`already landed: ${(heads[index] ?? '').slice(0, 7)} is on origin/${defaultBranch} (${(unit.landedAt ?? '').slice(0, 7)}); nothing is merged or pushed`);
    }
  } else {
    const landingUnits: LandingUnit[] = units.map((unit, index) => ({
      branch: unit.branch ?? '',
      head: heads[index] ?? '',
      subject: mergeSubject(read[index]?.title ?? '', unit.branch ?? '', unit.ref, codeRepository),
    }));
    const landing = await landReviewedHeads(context, api, { units: landingUnits, defaultBranch, trailers: reviewers.map((reviewer) => `Reviewed-by: ${reviewer}`), codeRepository, number: ref.number });
    landedCommits = landing.commits;
    landedNow = true;
    const finalCommit = landedCommits[landedCommits.length - 1] ?? '';
    lines.push(...landing.lines, `integrated: ${finalCommit.slice(0, 7)} on origin/${defaultBranch}, ${landingUnits.map((unit) => unit.subject).join('; ')}, Reviewed-by: ${reviewers.join(', ')}`);
    const checkout = await git.mainCheckout(cwd);
    const refreshed = await context.harness.refreshCheckout(checkout);
    if (refreshed.succeeded) {
      if (refreshed.output !== '') lines.push(refreshed.output);
    } else {
      warnings.push(refreshed.output, `integration succeeded: ${finalCommit.slice(0, 7)} is on origin/${defaultBranch}; the refresh of checkout ${checkout} did not finish (see above)`);
    }
  }

  const done: string[] = [`${landedNow ? 'landed' : 'found'} ${landedCommits[landedCommits.length - 1] ?? ''} on origin/${defaultBranch}`];
  try {
    for (const [index, issue] of read.entries()) {
      // An issue after the list belongs to --also: it shares the landing of the first issue.
      const position = index < units.length ? index : 0;
      const head = heads[position] ?? '';
      const landedCommit = landedCommits[position] ?? '';
      const entries = await readTimeline(api, issue.ref);
      if (hasLandedRecord(entries, head, landedCommit)) {
        done.push(`${formatIssue(issue.ref)} keeps its status: the record "Landed on ${defaultBranch}" is there already`);
        lines.push(`${formatIssue(issue.ref)} keeps its status: the record "Landed on ${defaultBranch}" is there already`);
        continue;
      }
      // The label first: a run interrupted between the two writes finds no record and does both again.
      await replaceFamilyLabel(api, issue.ref, issue, statusLabel('testing'));
      await addComment(api, issue.ref, composeLandedRecord({ branch: defaultBranch, repository: codeRepository, reviewedHead: head, landedCommit, reviewers }, issue.ref));
      done.push(`${formatIssue(issue.ref)} -> ${statusLabel('testing')} with the record "Landed on ${defaultBranch}"`);
      lines.push(`${formatIssue(issue.ref)} -> ${statusLabel('testing')}; recorded "Landed on ${defaultBranch}"`);
    }
  } catch (error) {
    throw new PartialCompletionError('record the landing', done, `${error instanceof Error ? error.message : String(error)}. The work is on origin/${defaultBranch}; run the same command again, it writes only what is missing`);
  }
  for (const unit of units) lines.push(`next: ai-core finish-issue ${formatRepository(unit.ref)} ${unit.ref.number}`);
  return succeeded(lines, warnings);
}
