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
import { listOf, parseArguments, parseIssueReference, refuseExtra, requireValue, takeIssueOfWorktree } from './arguments.mts';
import { succeeded } from './command.mts';
import type { CommandContext, CommandResult } from './command.mts';

const USAGE = 'usage: integrate-issue [OWNER/REPO] NUMBER --reviewed-by NAME [--reviewed-by NAME ...] --reviewed-head SHA [--also OWNER/REPO#NUMBER ...]';
export const help = `${USAGE}

Lands the reviewed branch of one issue on the default branch of origin: a merge commit that names the issue and
carries a "Reviewed-by: NAME" line for each reviewer, pushed through the push gate of the repository. Run it in
the worktree of the issue, on its branch, after the reviewer's GO. Where the push gate is the check, the merge
is made and pushed in that worktree, detached on origin/<default>, so the gate finds the tools installed there,
and the worktree is on its branch again afterwards, whether the push landed or was refused; a run stopped
before that leaves it detached, and its first line names the git switch that puts it back. The lines of git and
of the push gate show while the push runs. Where the checks of Forgejo are read, the merge is made in a
temporary worktree, where scripts/install.sh of the merged tree runs first if it has one, its lines shown, and
a failing install refuses the landing with nothing pushed. Then every issue it lands (the one given and each
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
and writes only the records that are missing. That rerun goes in the worktree of the issue, on its branch, and,
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

interface Landing {
  readonly commit: string;
  readonly lines: string[];
}

async function landReviewedHead(context: CommandContext, api: ForgejoClient, input: {
  readonly branch: string;
  readonly defaultBranch: string;
  readonly head: string;
  readonly subject: string;
  readonly trailers: readonly string[];
  readonly codeRepository: RepositoryRef;
  readonly number: number;
}): Promise<Landing> {
  const { git, cwd } = context;
  const { branch, defaultBranch, head } = input;
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
  let landed: string | undefined;
  let failure: unknown;
  try {
    if (checked) {
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
    let merged: string;
    try {
      merged = await git.merge(tree, head, `${input.subject}\n\n${input.trailers.join('\n')}`);
    } catch (error) {
      throw refusal(error, `${branch} does not merge cleanly into origin/${defaultBranch}: bring origin/${defaultBranch} into the branch, get the review of the result, then run this again`);
    }

    if (checked) {
      if (existsSync(join(tree, 'scripts', 'install.sh'))) {
        context.stderr(`installing: scripts/install.sh of the merged tree runs in ${tree}, so the gate's check finds what it needs\n`);
        const installed = await context.harness.installTools(tree, context.stderr);
        if (!installed.succeeded) throw new PreconditionError(`nothing landed: scripts/install.sh failed in the temporary worktree, nothing was pushed and the worktree of ${branch} is as it was (${installed.output.split('\n').join(' | ')})`);
      }
      const ciBranch = `ci/integrate-${branch}`;
      const held = await git.remoteBranchTip(cwd, ciBranch);
      try {
        await git.pushWithLease(tree, merged, ciBranch, held, context.stderr);
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
      await git.push(tree, merged, defaultBranch, context.stderr);
    } catch (error) {
      throw refusal(error, `the push to ${defaultBranch} was refused; nothing reached origin`);
    }
    landed = merged;
  } catch (error) {
    failure = error;
  } finally {
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
  return { commit: landed, lines: [...lines, ...notes] };
}

export async function run(args: readonly string[], context: CommandContext): Promise<CommandResult> {
  const parsed = parseArguments(args, { '--reviewed-by': 'repeat', '--reviewed-head': 'value', '--also': 'repeat' });
  const { ref, rest } = await takeIssueOfWorktree(parsed.positionals, context.git, context.cwd, USAGE);
  refuseExtra(rest, USAGE);
  const reviewers = parseReviewers(listOf(parsed, '--reviewed-by'));
  const reviewedHeadArgument = requireValue(parsed, '--reviewed-head');
  if (!/^[0-9a-fA-F]{7,64}$/.test(reviewedHeadArgument)) throw new UsageError(`--reviewed-head must be a commit id of at least 7 hexadecimal digits, not '${reviewedHeadArgument}'`);
  const issues: IssueRef[] = [ref];
  for (const text of listOf(parsed, '--also')) {
    const other = parseIssueReference(text);
    if (!issues.some((known) => isSameIssue(known, other))) issues.push(other);
  }

  const { git, cwd } = context;
  const codeRepository = await git.originRepository(cwd);
  const defaultBranch = await git.defaultBranch(cwd);
  await git.fetchBranch(cwd, defaultBranch);
  const defaultRef = `refs/remotes/origin/${defaultBranch}`;
  const defaultTip = await git.resolveCommit(cwd, defaultRef);
  const branch = await git.currentBranch(cwd);
  const issueBranch = branch !== undefined && new RegExp(`^issue-${ref.number}(-.*)?$`).test(branch) ? branch : undefined;
  const reviewedHead = await git.resolveCommit(cwd, reviewedHeadArgument).catch((error: unknown) => {
    if (error instanceof GitError) return undefined;
    throw error;
  });
  const isLanded = reviewedHead !== undefined && (await git.isAncestor(cwd, reviewedHead, defaultTip));
  // A reviewed head on origin/<default> is landed already, and only its records are missing; any other has to be merged from the branch.
  let target: { readonly landedAt: string } | { readonly branch: string };
  if (isLanded) target = { landedAt: await git.findLandingCommit(cwd, reviewedHead, defaultRef) };
  else if (issueBranch === undefined) throw new PreconditionError(`this runs in the worktree of issue ${ref.number}, on its branch issue-${ref.number}-*; here ${branch ?? 'no branch'} is checked out`);
  else target = { branch: issueBranch };
  if (issueBranch !== undefined) {
    const changes = await git.listChanges(cwd);
    if (changes.length > 0) {
      const shown = changes.length > SHOWN_CHANGES ? [...changes.slice(0, SHOWN_CHANGES), `and ${changes.length - SHOWN_CHANGES} more, ${changes.length} in all`] : changes;
      throw new PreconditionError(`the worktree has changes: commit them for the review, or put them aside, then run this again\n${shown.join('\n')}`);
    }
  }
  // Without the branch of the issue to tie the landed head to the issue (the worktree is gone, or was cut again), the
  // commit that landed it must name the issue, as this command writes it.
  if (isLanded && 'landedAt' in target) {
    const headIsReviewed = issueBranch !== undefined && (await git.resolveCommit(cwd, 'HEAD')) === reviewedHead;
    const name = issueName(ref, codeRepository);
    if (!headIsReviewed && !(await git.getSubject(cwd, target.landedAt)).endsWith(`(${name})`)) {
      throw new PreconditionError(
        `nothing is written: ${reviewedHead} is on origin/${defaultBranch}, but in the commit ${target.landedAt.slice(0, 7)}, whose subject does not end with (${name}), so it is not shown to be the work of ${formatIssue(ref)}; ` +
          `run the same command in the worktree of the issue, on ${reviewedHead.slice(0, 7)}`,
      );
    }
  }

  const api = context.api();
  const login = await currentLogin(api);
  const read: Issue[] = [];
  for (const issueRef of issues) {
    const issue = await getIssue(api, issueRef);
    if (issue.state !== 'open') throw new PreconditionError(`${formatIssue(issueRef)} is closed: work lands on an open issue`);
    const unassigned = explainMissingAssignment(issue, login);
    if (unassigned !== undefined) throw new PreconditionError(unassigned);
    read.push(issue);
  }

  if (reviewedHead === undefined) throw new PreconditionError(`--reviewed-head ${reviewedHeadArgument} is no commit of this clone`);
  let head = reviewedHead;
  if ('branch' in target) {
    head = await git.resolveCommit(cwd, 'HEAD');
    if (head !== reviewedHead) {
      throw new PreconditionError(`nothing landed: the head of ${target.branch} is ${head}, not the reviewed head ${reviewedHead}; the branch changed after the review`);
    }
  }

  const lines: string[] = [];
  const warnings: string[] = [];
  let landedCommit: string;
  let landedNow = false;
  if ('landedAt' in target) {
    landedCommit = target.landedAt;
    lines.push(`already landed: ${head.slice(0, 7)} is on origin/${defaultBranch} (${landedCommit.slice(0, 7)}); nothing is merged or pushed`);
  } else {
    const first = read[0];
    const subject = mergeSubject(first?.title ?? '', target.branch, ref, codeRepository);
    const landing = await landReviewedHead(context, api, { branch: target.branch, defaultBranch, head, subject, trailers: reviewers.map((reviewer) => `Reviewed-by: ${reviewer}`), codeRepository, number: ref.number });
    landedCommit = landing.commit;
    landedNow = true;
    lines.push(...landing.lines, `integrated: ${landedCommit.slice(0, 7)} on origin/${defaultBranch}, ${subject}, Reviewed-by: ${reviewers.join(', ')}`);
    const checkout = await git.mainCheckout(cwd);
    const refreshed = await context.harness.refreshCheckout(checkout);
    if (refreshed.succeeded) {
      if (refreshed.output !== '') lines.push(refreshed.output);
    } else {
      warnings.push(refreshed.output, `integration succeeded: ${landedCommit.slice(0, 7)} is on origin/${defaultBranch}; the refresh of checkout ${checkout} did not finish (see above)`);
    }
  }

  const done: string[] = [`${landedNow ? 'landed' : 'found'} ${landedCommit} on origin/${defaultBranch}`];
  try {
    for (const issue of read) {
      const entries = await readTimeline(api, issue.ref);
      if (!hasLandedRecord(entries, head, landedCommit)) {
        await addComment(api, issue.ref, composeLandedRecord({ branch: defaultBranch, repository: codeRepository, reviewedHead: head, landedCommit, reviewers }, issue.ref));
      }
      await replaceFamilyLabel(api, issue.ref, issue, statusLabel('testing'));
      done.push(`${formatIssue(issue.ref)} -> ${statusLabel('testing')} with the record "Landed on ${defaultBranch}"`);
      lines.push(`${formatIssue(issue.ref)} -> ${statusLabel('testing')}; recorded "Landed on ${defaultBranch}"`);
    }
  } catch (error) {
    throw new PartialCompletionError('record the landing', done, `${error instanceof Error ? error.message : String(error)}. The work is on origin/${defaultBranch}; run the same command again, it writes only what is missing`);
  }
  lines.push(`next: ai-core finish-issue ${formatRepository(ref)} ${ref.number}`);
  return succeeded(lines, warnings);
}
