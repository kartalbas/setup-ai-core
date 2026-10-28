import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, it } from 'node:test';
import { ContractError, PermissionError } from '../api/client.mts';
import { clientFor, seedLabels, startFakeForgejo } from '../testing/fake-forgejo.mts';
import type { FakeForgejo } from '../testing/fake-forgejo.mts';
import { editIssue, getIssue } from './issues.mts';
import type { IssueRef } from './issues.mts';
import { replaceFamilyLabel } from './labels.mts';
import { ensureReleaseMilestone, setReleaseMilestone } from './milestones.mts';
import {
  composeLandedRecord,
  composeProvenRecord,
  composeReleasedRecord,
  composeStartedRecord,
  findCurrentProof,
  hasLandedRecord,
  hasProvenRecord,
  hasReleasedRecord,
  hasStartedRecord,
  environmentsWith,
  landedEnvironments,
  listMissingDelivery,
  readIssueHistory,
  readTimeline,
} from './workflow.mts';
import { UsageError } from './refusals.mts';

const HEAD = 'b'.repeat(40);
const MERGE = 'c'.repeat(40);
const code = { owner: 'o', repo: 'r' };
const other = { owner: 'p', repo: 's' };

describe('the text of the records', () => {
  it('opens a landing in the repository of the issue with "Landed on <branch>:" and names another repository when the work landed there', () => {
    const landed = { branch: 'master', repository: code, reviewedHead: HEAD, landedCommit: MERGE, reviewers: ['alice', 'bob'] };
    assert.match(composeLandedRecord(landed, code), /^Landed on master:\n\nReviewed head: b{40}\nLanded commit: c{40}\nReviewed by: alice, bob\n$/);
    assert.match(composeLandedRecord(landed, other), /^Landed on master of o\/r:\n/);
  });

  it('opens the other records with their one line', () => {
    assert.equal(composeStartedRecord({ branch: 'issue-3-x', baseBranch: 'master', baseCommit: HEAD }), `Started on issue-3-x:\n\nBase: master at ${HEAD}\n`);
    assert.equal(composeReleasedRecord(code, 'v1.2.3'), 'Released in o/r v1.2.3:\n');
    assert.equal(composeProvenRecord('prod', 'Seen working.\n\n'), 'Proven on prod:\n\nSeen working.\n');
  });
});

describe('the environments where a landing is the delivery', () => {
  it('are those of LIVE_TAGS with the pattern landed', () => {
    assert.deepEqual(landedEnvironments('prod=landed test=deploy/test/*'), ['prod']);
    assert.deepEqual(landedEnvironments('prod=deploy/prod/* test=landed'), ['test']);
    assert.deepEqual(landedEnvironments(undefined), []);
    assert.deepEqual(landedEnvironments(''), []);
  });

  it('refuse an entry that is no env=pattern', () => {
    assert.throws(() => landedEnvironments('prod'), UsageError);
    assert.throws(() => landedEnvironments('prod='), UsageError);
  });

  it('are read by the same reader that names the environments of the pattern command', () => {
    assert.deepEqual(environmentsWith('prod=command test=landed', 'command'), ['prod']);
    assert.deepEqual(environmentsWith('prod=command test=landed', 'landed'), ['test']);
    assert.throws(() => environmentsWith('prod', 'command'), UsageError);
  });
});

describe('a delivery that a project\'s reader answers', () => {
  const pinned = { owner: 'o', repo: 'pinned' };
  const landedIn = { deliveryReopenedAt: undefined, landings: [{ at: 1, branch: 'master', repository: pinned, commit: 'c'.repeat(40), isPart: false }], releases: [], proofs: [] };

  it('counts where the reader delivered the landing, and names the reason where it did not, in place of a missing release (planted)', () => {
    assert.deepEqual(listMissingDelivery(landedIn, [], [{ repository: pinned, missing: undefined }]), []);
    assert.deepEqual(listMissingDelivery(landedIn, [], [{ repository: pinned, missing: 'the reader of o/pinned found no completed delivery on prod' }]), ['the reader of o/pinned found no completed delivery on prod']);
  });

  it('leaves a repository no reader answered to its release (innocent case)', () => {
    assert.match(listMissingDelivery(landedIn, []).join(), /no release of o\/pinned follows its landing/);
  });
});

describe('what an issue records', () => {
  let fake: FakeForgejo;
  let ref: IssueRef;
  before(async () => {
    fake = await startFakeForgejo();
    fake.addRepository('o/r');
    seedLabels(fake, 'o');
    fake.setPermission('o/r', 'writer', 'write');
    fake.setPermission('o/r', 'admin', 'admin');
    fake.setPermission('o/r', 'reader', 'read');
  });
  after(async () => {
    await fake.close();
  });
  beforeEach(() => {
    ref = { ...code, number: fake.addIssue('o/r', { title: 'Recorded, so that it has a history' }) };
  });

  const landing = (head = HEAD): string => composeLandedRecord({ branch: 'master', repository: code, reviewedHead: head, landedCommit: MERGE, reviewers: ['r'] }, code);
  const history = async (): ReturnType<typeof readIssueHistory> => {
    const api = clientFor(fake);
    return readIssueHistory(api, await getIssue(api, ref), await readTimeline(api, ref));
  };
  const reopen = async (): Promise<void> => {
    const api = clientFor(fake);
    await editIssue(api, ref, { state: 'closed' });
    await editIssue(api, ref, { state: 'open' });
  };

  it('counts a landing, a release and a proof of an account with write permission, in the order they came', async () => {
    fake.addComment('o/r', ref.number, 'writer', landing());
    fake.addComment('o/r', ref.number, 'admin', composeReleasedRecord(code, 'v1'));
    fake.addComment('o/r', ref.number, 'writer', composeProvenRecord('prod', 'ok'));
    const found = await history();
    assert.equal(found.landings.length, 1);
    assert.equal(found.landings[0]?.commit, MERGE);
    assert.equal(found.releases.length, 1);
    assert.equal(found.proofs[0]?.environment, 'prod');
    assert.deepEqual(listMissingDelivery(found, []), []);
    assert.notEqual(findCurrentProof(found), undefined);
  });

  it('counts nothing from an account that may not write, nor from one Forgejo does not know (planted: a stranger writes the records)', async () => {
    fake.addComment('o/r', ref.number, 'reader', landing());
    fake.addComment('o/r', ref.number, 'reader', composeReleasedRecord(code, 'v1'));
    fake.addComment('o/r', ref.number, 'reader', composeProvenRecord('prod', 'ok'));
    const found = await history();
    assert.deepEqual([found.landings.length, found.releases.length, found.proofs.length], [0, 0, 0]);
    assert.match(listMissingDelivery(found, []).join(), /no "Landed on" record/);
    assert.equal(findCurrentProof(found), undefined);
    fake.fail({ method: 'GET', path: '/repos/o/r/collaborators/nobody/permission', mode: { kind: 'status', status: 404, message: 'user does not exist' } });
    fake.addComment('o/r', ref.number, 'nobody', landing());
    assert.equal((await history()).landings.length, 0);
  });

  it('says why when Forgejo will not tell the permission of another account, and never reads it as "no permission"', async () => {
    fake.addComment('o/r', ref.number, 'writer', landing());
    fake.fail({ method: 'GET', path: '/repos/o/r/collaborators/writer/permission', mode: { kind: 'status', status: 403, message: 'Only admins can query all permissions' } });
    await assert.rejects(history(), (error: unknown) => error instanceof PermissionError && /administrator of the repository/.test(error.message) && /read the permission of writer in o\/r/.test(error.message));
  });

  it('ignores every record from before the last reopening (planted: an old landing and an old proof)', async () => {
    fake.addComment('o/r', ref.number, 'writer', landing());
    fake.addComment('o/r', ref.number, 'writer', composeReleasedRecord(code, 'v1'));
    fake.addComment('o/r', ref.number, 'writer', composeProvenRecord('prod', 'ok'));
    await reopen();
    const stale = await history();
    assert.deepEqual([stale.landings.length, stale.releases.length, stale.proofs.length], [0, 0, 0]);
    assert.notEqual(stale.deliveryReopenedAt, undefined);
    fake.addComment('o/r', ref.number, 'writer', landing('d'.repeat(40)));
    assert.equal((await history()).landings.length, 1);
  });

  it('keeps landings and releases across a reopening to testing, but drops the earlier proofs', async () => {
    const api = clientFor(fake);
    fake.addComment('o/r', ref.number, 'writer', landing());
    fake.addComment('o/r', ref.number, 'writer', composeReleasedRecord(code, 'v1'));
    const { milestone } = await ensureReleaseMilestone(api, code, 'v1');
    await setReleaseMilestone(api, ref, milestone);
    fake.addComment('o/r', ref.number, 'writer', composeProvenRecord('prod', 'ok'));
    await replaceFamilyLabel(api, ref, await getIssue(api, ref), 'status/done');
    await reopen();
    fake.addLabelEvent('o/r', ref.number, 'reader', 'status/ready', true);
    fake.addLabelEvent('o/r', ref.number, 'writer', 'priority/p1', true);
    await replaceFamilyLabel(api, ref, await getIssue(api, ref), 'status/testing');
    const found = await history();
    assert.deepEqual([found.landings.length, found.releases.length, found.proofs.length], [1, 2, 0]);
    assert.equal(found.deliveryReopenedAt, undefined);
    assert.deepEqual(listMissingDelivery(found, []), []);
    assert.equal(findCurrentProof(found), undefined);
    fake.addComment('o/r', ref.number, 'writer', composeProvenRecord('prod', 'shown again'));
    assert.notEqual(findCurrentProof(await history()), undefined);
  });

  it('wants a release and a proof after a landing that comes after a reopening to testing', async () => {
    const api = clientFor(fake);
    fake.addComment('o/r', ref.number, 'writer', landing());
    const { milestone } = await ensureReleaseMilestone(api, code, 'v1');
    await setReleaseMilestone(api, ref, milestone);
    await reopen();
    fake.addLabelEvent('o/r', ref.number, 'writer', 'status/testing', true);
    fake.addComment('o/r', ref.number, 'writer', composeProvenRecord('prod', 'before the second landing'));
    fake.addComment('o/r', ref.number, 'writer', landing('d'.repeat(40)));
    const landedAgain = await history();
    assert.match(listMissingDelivery(landedAgain, []).join(), /no release of o\/r follows its landing/);
    assert.equal(findCurrentProof(landedAgain), undefined);
    fake.addComment('o/r', ref.number, 'writer', composeReleasedRecord(code, 'v2'));
    const released = await history();
    assert.deepEqual(listMissingDelivery(released, []), []);
    assert.equal(findCurrentProof(released), undefined);
    fake.addComment('o/r', ref.number, 'writer', composeProvenRecord('prod', 'after the second landing'));
    assert.notEqual(findCurrentProof(await history()), undefined);
  });

  it('starts new work at the first added status after a reopening, even when testing is added later', async () => {
    const api = clientFor(fake);
    fake.addComment('o/r', ref.number, 'writer', landing());
    fake.addComment('o/r', ref.number, 'writer', composeReleasedRecord(code, 'v1'));
    const { milestone } = await ensureReleaseMilestone(api, code, 'v1');
    await setReleaseMilestone(api, ref, milestone);
    fake.addComment('o/r', ref.number, 'writer', composeProvenRecord('prod', 'ok'));
    await reopen();
    fake.addLabelEvent('o/r', ref.number, 'writer', 'status/ready', true);
    fake.addLabelEvent('o/r', ref.number, 'writer', 'status/testing', true);
    const found = await history();
    assert.deepEqual([found.landings.length, found.releases.length, found.proofs.length], [0, 0, 0]);
    assert.notEqual(found.deliveryReopenedAt, undefined);
    assert.match(listMissingDelivery(found, []).join(), /follows the last reopening for new work/);
  });

  it('does not keep delivery for a testing label from an account without write permission (planted)', async () => {
    fake.addComment('o/r', ref.number, 'writer', landing());
    fake.addComment('o/r', ref.number, 'writer', composeReleasedRecord(code, 'v1'));
    fake.addComment('o/r', ref.number, 'writer', composeProvenRecord('prod', 'ok'));
    await reopen();
    fake.addLabelEvent('o/r', ref.number, 'reader', 'status/testing', true);
    const found = await history();
    assert.deepEqual([found.landings.length, found.releases.length, found.proofs.length], [0, 0, 0]);
    assert.notEqual(found.deliveryReopenedAt, undefined);
    assert.match(listMissingDelivery(found, []).join(), /follows the last reopening for new work/);
  });

  it('keeps only the delivery after the last reopening for new work across later testing reopenings', async () => {
    fake.addComment('o/r', ref.number, 'writer', landing());
    fake.addComment('o/r', ref.number, 'writer', composeReleasedRecord(code, 'v0'));
    await reopen();
    fake.addLabelEvent('o/r', ref.number, 'writer', 'status/ready', true);
    const first = await history();
    fake.addComment('o/r', ref.number, 'writer', landing('d'.repeat(40)));
    fake.addComment('o/r', ref.number, 'writer', composeReleasedRecord(code, 'v1'));
    for (let n = 0; n < 2; n++) {
      fake.addComment('o/r', ref.number, 'writer', composeProvenRecord('prod', 'ok'));
      await reopen();
      fake.addLabelEvent('o/r', ref.number, 'writer', 'status/testing', true);
      const found = await history();
      assert.deepEqual([found.landings.length, found.releases.length, found.proofs.length], [1, 1, 0]);
      assert.equal(found.releases[0]?.tag, 'v1');
      assert.equal(found.deliveryReopenedAt, first.deliveryReopenedAt);
    }
  });

  it('reads the timeline in order when every timestamp is equal: a proof before the reopening is dropped, one after it counts', async () => {
    fake.addComment('o/r', ref.number, 'writer', landing());
    fake.addComment('o/r', ref.number, 'writer', composeReleasedRecord(code, 'v1'));
    fake.addComment('o/r', ref.number, 'writer', composeProvenRecord('prod', 'before'));
    await reopen();
    fake.addLabelEvent('o/r', ref.number, 'writer', 'status/done', false);
    fake.addLabelEvent('o/r', ref.number, 'writer', 'status/testing', true);
    fake.addComment('o/r', ref.number, 'writer', composeProvenRecord('prod', 'after'));
    const api = clientFor(fake);
    const entries = await readTimeline(api, ref);
    const sameTime = entries.map((entry) => ({ ...entry, at: 0 }));
    const found = await readIssueHistory(api, await getIssue(api, ref), sameTime);
    assert.deepEqual([found.landings.length, found.releases.length, found.proofs.length], [1, 1, 1]);
  });

  it('starts new work at a reopening with no status label added, as the web page reopens', async () => {
    fake.addComment('o/r', ref.number, 'writer', landing());
    fake.addComment('o/r', ref.number, 'writer', composeReleasedRecord(code, 'v1'));
    await reopen();
    const found = await history();
    assert.deepEqual([found.landings.length, found.releases.length], [0, 0]);
    assert.notEqual(found.deliveryReopenedAt, undefined);
  });

  it('wants a release after the landing it carries, and a proof after the newest landing', async () => {
    fake.addComment('o/r', ref.number, 'writer', composeReleasedRecord(code, 'v0'));
    fake.addComment('o/r', ref.number, 'writer', landing());
    let found = await history();
    assert.match(listMissingDelivery(found, []).join(), /no release of o\/r follows its landing/);
    fake.addComment('o/r', ref.number, 'writer', composeProvenRecord('prod', 'too early'));
    fake.addComment('o/r', ref.number, 'writer', composeReleasedRecord(code, 'v1'));
    found = await history();
    assert.deepEqual(listMissingDelivery(found, []), []);
    assert.notEqual(findCurrentProof(found), undefined, 'the proof came after the landing');
    fake.addComment('o/r', ref.number, 'writer', landing('e'.repeat(40)));
    found = await history();
    assert.equal(findCurrentProof(found), undefined, 'a proof of earlier work does not cover a later landing');
    assert.match(listMissingDelivery(found, []).join(), /no release of o\/r follows its landing/);
  });

  it('takes the milestone of the issue as the release of its own repository, when it was set after the landing', async () => {
    const api = clientFor(fake);
    const { milestone } = await ensureReleaseMilestone(api, code, 'v1');
    await setReleaseMilestone(api, ref, milestone);
    fake.addComment('o/r', ref.number, 'writer', landing());
    assert.match(listMissingDelivery(await history(), []).join(), /no release of o\/r follows its landing/);
    await editIssue(api, ref, { milestone: 0 });
    await setReleaseMilestone(api, ref, milestone);
    assert.deepEqual(listMissingDelivery(await history(), []), []);
    await editIssue(api, ref, { milestone: 0 });
    assert.match(listMissingDelivery(await history(), []).join(), /no release/);
  });

  it('asks a release for every repository the landings name, and none where the landing is the delivery', async () => {
    fake.addComment('o/r', ref.number, 'writer', landing());
    fake.addComment('o/r', ref.number, 'writer', composeLandedRecord({ branch: 'master', repository: other, reviewedHead: HEAD, landedCommit: MERGE, reviewers: ['r'] }, code));
    fake.addComment('o/r', ref.number, 'writer', composeReleasedRecord(code, 'v1'));
    const found = await history();
    assert.deepEqual(found.landings.map((entry) => `${entry.repository.owner}/${entry.repository.repo}`), ['o/r', 'p/s']);
    assert.match(listMissingDelivery(found, []).join(), /no release of p\/s/);
    assert.deepEqual(listMissingDelivery(found, [other]), []);
    fake.addComment('o/r', ref.number, 'writer', composeReleasedRecord(other, 'v7'));
    assert.deepEqual(listMissingDelivery(await history(), []), []);
  });

  it('takes the landing of a harness layer as its delivery, and not the landing of setup-ai-core', async () => {
    const landedIn = (repository: { owner: string; repo: string }): string =>
      composeLandedRecord({ branch: 'master', repository, reviewedHead: HEAD, landedCommit: MERGE, reviewers: ['r'] }, code);
    fake.addComment('o/r', ref.number, 'writer', landedIn({ owner: 'o', repo: 'shop-AI-core' }));
    assert.deepEqual(listMissingDelivery(await history(), []), []);
    fake.addComment('o/r', ref.number, 'writer', landedIn({ owner: 'o', repo: 'setup-ai-core' }));
    assert.match(listMissingDelivery(await history(), []).join(), /no release of o\/setup-ai-core follows its landing/);
  });

  it('reads a timeline of several pages whole', async () => {
    for (let n = 0; n < 120; n++) fake.addComment('o/r', ref.number, 'writer', `comment ${n}`);
    fake.addComment('o/r', ref.number, 'writer', landing());
    const api = clientFor(fake);
    const entries = await readTimeline(api, ref);
    assert.equal(entries.length, 121);
    assert.equal((await readIssueHistory(api, await getIssue(api, ref), entries)).landings.length, 1);
  });

  it('refuses a timeline entry that lacks its time (planted: the field is missing)', async () => {
    fake.addComment('o/r', ref.number, 'writer', 'x');
    fake.fail({ method: 'GET', path: `/repos/o/r/issues/${ref.number}/timeline`, mode: { kind: 'omit-field', field: 'created_at' } });
    await assert.rejects(readTimeline(clientFor(fake), ref), ContractError);
  });

  it('leaves out a timeline entry that Forgejo answers as null, and reads the records around it', async () => {
    fake.addComment('o/r', ref.number, 'writer', 'before');
    fake.addComment('o/r', ref.number, 'writer', landing());
    fake.fail({ method: 'GET', path: `/repos/o/r/issues/${ref.number}/timeline`, mode: { kind: 'insert-null', at: 1 } });
    const api = clientFor(fake);
    const entries = await readTimeline(api, ref);
    assert.deepEqual(entries.map((entry) => entry.body), ['before', landing()]);
    assert.equal(hasLandedRecord(entries, HEAD, MERGE), true);
  });

  it('finds a record that is written already, and none that is not (what makes a second run write only what is missing)', async () => {
    fake.addComment('o/r', ref.number, 'writer', composeStartedRecord({ branch: 'issue-1-x', baseBranch: 'master', baseCommit: HEAD }));
    fake.addComment('o/r', ref.number, 'writer', landing());
    fake.addComment('o/r', ref.number, 'writer', composeReleasedRecord(other, 'v1'));
    fake.addComment('o/r', ref.number, 'writer', composeProvenRecord('prod', 'ok'));
    const entries = await readTimeline(clientFor(fake), ref);
    assert.equal(hasStartedRecord(entries, 'issue-1-x'), true);
    assert.equal(hasStartedRecord(entries, 'issue-2-y'), false);
    assert.equal(hasLandedRecord(entries, HEAD, MERGE), true);
    assert.equal(hasLandedRecord(entries, HEAD, 'f'.repeat(40)), false);
    assert.equal(hasReleasedRecord(entries, other, 'v1'), true);
    assert.equal(hasReleasedRecord(entries, other, 'v2'), false);
    assert.equal(hasReleasedRecord(entries, code, 'v1'), false);
    const found = await history();
    assert.equal(hasProvenRecord(found, 'prod'), true);
    assert.equal(hasProvenRecord(found, 'test'), false);
    fake.addComment('o/r', ref.number, 'writer', landing('d'.repeat(40)));
    assert.equal(hasProvenRecord(await history(), 'prod'), false, 'the proof came before the newest landing');
    fake.addComment('o/r', ref.number, 'reader', composeProvenRecord('prod', 'faked'));
    assert.equal(hasProvenRecord(await history(), 'prod'), false, 'planted: a proof of an account that may not write');
  });
});
