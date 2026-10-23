import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import { ContractError } from '../api/client.mts';
import { clientFor, startFakeForgejo } from '../testing/fake-forgejo.mts';
import type { FakeForgejo } from '../testing/fake-forgejo.mts';
import { readChecks, readVisibility, waitForChecks } from './checks.mts';

const SHA = 'a'.repeat(40);

describe('the checks of a commit', () => {
  let fake: FakeForgejo;
  const repository = { owner: 'o', repo: 'r' };
  before(async () => {
    fake = await startFakeForgejo();
    fake.addRepository('o/r');
    fake.addRepository('o/hidden', { isPrivate: true });
  });
  after(async () => {
    await fake.close();
  });

  it('read the visibility of a repository, and fail where Forgejo does not answer (planted: 404)', async () => {
    const api = clientFor(fake);
    assert.equal(await readVisibility(api, repository), 'public');
    assert.equal(await readVisibility(api, { owner: 'o', repo: 'hidden' }), 'private');
    await assert.rejects(readVisibility(api, { owner: 'o', repo: 'nothing' }), /read the visibility of o\/nothing/);
  });

  const cases: [string[], string][] = [
    [['success'], 'green'],
    [['failure'], 'red'],
    [['error'], 'red'],
    [['warning'], 'red'],
    [['pending'], 'pending'],
    [[], 'pending'],
  ];
  for (const [states, expected] of cases) {
    it(`say ${expected} for ${states.length === 0 ? 'a commit no check reported on' : states[0]}`, async () => {
      fake.setChecks('o/r', states);
      assert.equal(await readChecks(clientFor(fake), repository, SHA), expected);
    });
  }

  it('refuse a state they do not know instead of guessing (planted: unknown state)', async () => {
    fake.setChecks('o/r', ['bogus']);
    await assert.rejects(readChecks(clientFor(fake), repository, SHA), ContractError);
  });

  it('wait through pending until green (innocent case), and stop at red', async () => {
    const waiting = { pollMilliseconds: 5, limitMilliseconds: 5000 };
    fake.setChecks('o/r', ['pending', 'pending', 'success']);
    let announced = 0;
    assert.equal(await waitForChecks(clientFor(fake), repository, SHA, waiting, () => announced++), 'green');
    assert.equal(announced, 1);
    fake.setChecks('o/r', ['pending', 'failure']);
    assert.equal(await waitForChecks(clientFor(fake), repository, SHA, waiting, () => undefined), 'red');
  });

  it('give up when the checks do not finish within the limit (planted: pending for good)', async () => {
    fake.setChecks('o/r', ['pending']);
    assert.equal(await waitForChecks(clientFor(fake), repository, SHA, { pollMilliseconds: 5, limitMilliseconds: 40 }, () => undefined), 'unfinished');
  });
});
