import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import { ContractError, PermissionError } from '../api/client.mts';
import { clientFor, startFakeForgejo } from '../testing/fake-forgejo.mts';
import type { FakeForgejo } from '../testing/fake-forgejo.mts';
import { ensureReleaseMilestone, findReleaseMilestone, setReleaseMilestone, tagExists } from './milestones.mts';

describe('the release of a repository: its tag and its milestone', () => {
  let fake: FakeForgejo;
  const repository = { owner: 'o', repo: 'r' };
  const elsewhere = { owner: 'p', repo: 's' };
  before(async () => {
    fake = await startFakeForgejo();
    fake.addRepository('o/r');
    fake.addRepository('p/s');
    fake.addIssue('o/r', { title: 'Released, so that it is carried' });
    fake.addTag('o/r', 'v1.0.0');
  });
  after(async () => {
    await fake.close();
  });

  it('finds a tag that is there and reports one that is not (innocent case and planted: no tag)', async () => {
    const api = clientFor(fake);
    assert.equal(await tagExists(api, repository, 'v1.0.0'), true);
    assert.equal(await tagExists(api, repository, 'v9.9.9'), false);
  });

  it('never takes a refused read for a missing tag (planted: 403)', async () => {
    fake.fail({ method: 'GET', path: '/repos/o/r/tags/v1.0.0', mode: { kind: 'status', status: 403, message: 'planted' } });
    await assert.rejects(tagExists(clientFor(fake), repository, 'v1.0.0'), PermissionError);
  });

  it('makes the milestone named by the tag once and reuses it afterwards', async () => {
    const api = clientFor(fake);
    const first = await ensureReleaseMilestone(api, repository, 'v1.0.0');
    assert.equal(first.created, true);
    const second = await ensureReleaseMilestone(api, repository, 'v1.0.0');
    assert.equal(second.created, false);
    assert.equal(second.milestone.id, first.milestone.id);
    assert.deepEqual(fake.listMilestones('o/r').map((milestone) => milestone.title), ['v1.0.0']);
  });

  it('reuses no milestone of another repository, since a milestone belongs to one repository', async () => {
    const api = clientFor(fake);
    await ensureReleaseMilestone(api, elsewhere, 'v2.0.0');
    assert.equal(await findReleaseMilestone(api, repository, 'v2.0.0'), undefined);
    const made = await ensureReleaseMilestone(api, repository, 'v2.0.0');
    assert.equal(made.created, true);
    assert.deepEqual(fake.listMilestones('p/s').map((milestone) => milestone.title), ['v2.0.0']);
  });

  it('matches the whole title: v1.0 is not v1.0.0', async () => {
    assert.equal(await findReleaseMilestone(clientFor(fake), repository, 'v1.0'), undefined);
  });

  it('sets the milestone on the issue, and refuses an answer that kept none (planted: the field is missing)', async () => {
    const api = clientFor(fake);
    const { milestone } = await ensureReleaseMilestone(api, repository, 'v1.0.0');
    await setReleaseMilestone(api, { ...repository, number: 1 }, milestone);
    assert.equal(fake.readIssue('o/r', 1).milestone, 'v1.0.0');
    fake.fail({ method: 'PATCH', path: '/repos/o/r/issues/1', mode: { kind: 'omit-field', field: 'milestone' } });
    await assert.rejects(setReleaseMilestone(api, { ...repository, number: 1 }, milestone), (error: unknown) => error instanceof ContractError && /kept no milestone/.test(error.message));
  });
});
