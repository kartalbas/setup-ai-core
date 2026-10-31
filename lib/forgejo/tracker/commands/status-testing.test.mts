import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { after, before, describe, it } from 'node:test';
import { PreconditionError } from '../domain/refusals.mts';
import { contextFor, seedLabels, startFakeForgejo } from '../testing/fake-forgejo.mts';
import type { FakeForgejo } from '../testing/fake-forgejo.mts';
import { createRecordingHarness } from '../testing/recording-harness.mts';
import * as status from './status.mts';

interface Handed {
  items: { number: number; status: string; open: boolean }[];
  columns: string;
  records: { repository: string; number: number; context: string; reason: string; landing: { repository: string; commit: string; createdAt: string } | null; proofs: { environment: string; createdAt: string }[] }[];
  board: string;
}

const LANDED = (commit: string): string => `Landed on master:\n\nReviewed head: ${'a'.repeat(40)}\nLanded commit: ${commit}\nReviewed by: alice\n`;

describe('status: the testing block', () => {
  let fake: FakeForgejo;
  const handed: Handed[] = [];
  const numbers = { proven: 0, due: 0, unlanded: 0, unreadable: 0, strangerProof: 0, closed: 0, implementing: 0 };
  const commit = (letter: string): string => letter.repeat(40);

  before(async () => {
    fake = await startFakeForgejo();
    fake.addRepository('o/one');
    seedLabels(fake, 'o');
    numbers.proven = fake.addIssue('o/one', { title: 'Proven, so that it is shown as waiting to close', labels: ['status/testing'] });
    fake.addComment('o/one', numbers.proven, 'fake-user', LANDED(commit('1')));
    fake.addComment('o/one', numbers.proven, 'fake-user', 'Proven on prod:\n\nthe session read the page\n');
    numbers.due = fake.addIssue('o/one', { title: 'Landed without a proof, so that its proof is due', labels: ['status/testing'] });
    fake.addComment('o/one', numbers.due, 'fake-user', LANDED(commit('2')));
    numbers.unlanded = fake.addIssue('o/one', { title: 'Not landed, so that no landing is handed over', labels: ['status/testing'] });
    numbers.unreadable = fake.addIssue('o/one', { title: 'Timeline unreadable, so that it is its own failed record', labels: ['status/testing'] });
    numbers.strangerProof = fake.addIssue('o/one', { title: 'Proof of a stranger, so that it does not count', labels: ['status/testing'] });
    fake.addComment('o/one', numbers.strangerProof, 'fake-user', LANDED(commit('3')));
    fake.setPermission('o/one', 'stranger', 'read');
    fake.addComment('o/one', numbers.strangerProof, 'stranger', 'Proven on prod:\n\nclaimed by anybody\n');
    numbers.closed = fake.addIssue('o/one', { title: 'Closed in testing, so that it is not shown', state: 'closed', closedAt: '2026-01-01T06:00:00Z', labels: ['status/testing'] });
    numbers.implementing = fake.addIssue('o/one', { title: 'Still implementing, so that it is no testing card', labels: ['status/implementing'] });
    fake.fail({ method: 'GET', path: new RegExp(`/issues/${numbers.unreadable}/timeline`), times: 1000, mode: { kind: 'status', status: 403, message: 'planted: the timeline is not readable' } });
  });
  after(async () => {
    await fake.close();
  });

  const run = async (args: string[], page = 'THE BLOCK') => {
    handed.length = 0;
    const harness = createRecordingHarness();
    const context = contextFor(fake, {
      harness: {
        ...harness,
        readTestingPage: async (cwd, itemsFile, columnsFile, testingFile, board) => {
          const items = (await readFile(itemsFile, 'utf8')).trim().split('\n').map((line) => JSON.parse(line));
          const records = (await readFile(testingFile, 'utf8')).trim().split('\n').filter((line) => line !== '').map((line) => JSON.parse(line));
          handed.push({ items, columns: await readFile(columnsFile, 'utf8'), records, board });
          return harness.readTestingPage(cwd, itemsFile, columnsFile, testingFile, board).then((outcome) => ({ ...outcome, output: page }));
        },
      },
    });
    return { result: await status.run(args, context), harness };
  };

  it('hands over one record per open issue in testing, with its landing and its trusted proof, and ends the page with the block', async () => {
    const { result } = await run(['o/one']);
    assert.equal(result.exitCode, 0);
    assert.equal(result.stdout.trimEnd().split('\n').at(-1), 'THE BLOCK');
    assert.equal(handed.length, 1);
    const records = handed[0]?.records ?? [];
    assert.deepEqual(records.map((record) => record.number).sort((a, b) => a - b), [numbers.proven, numbers.due, numbers.unlanded, numbers.unreadable, numbers.strangerProof]);
    const byNumber = (number: number) => records.find((record) => record.number === number);
    assert.equal(byNumber(numbers.proven)?.landing?.commit, commit('1'));
    assert.equal(byNumber(numbers.proven)?.landing?.repository, 'o/one');
    assert.deepEqual(byNumber(numbers.proven)?.proofs.map((proof) => proof.environment), ['prod']);
    assert.equal(byNumber(numbers.due)?.landing?.commit, commit('2'));
    assert.deepEqual(byNumber(numbers.due)?.proofs, [], 'a landed card without a proof carries none');
    assert.equal(byNumber(numbers.unlanded)?.landing, null);
    assert.equal(byNumber(numbers.strangerProof)?.landing?.commit, commit('3'));
    assert.deepEqual(byNumber(numbers.strangerProof)?.proofs, [], 'a proof of an account without write permission counts for nothing');
  });

  it('writes the issue whose timeline could not be read as its own failed record and hides no other', async () => {
    await run(['o/one']);
    const records = handed[0]?.records ?? [];
    const failed = records.filter((record) => record.context === 'failed');
    assert.deepEqual(failed.map((record) => record.number), [numbers.unreadable]);
    assert.match(failed[0]?.reason ?? '', /planted: the timeline is not readable/);
    assert.equal(failed[0]?.landing, null);
    assert.equal(records.filter((record) => record.context === 'read').length, 4);
  });

  it('hands over the cards of the listed issues and the board, and leaves a closed issue in testing out of the records', async () => {
    await run(['o/one', '--state', 'all']);
    assert.deepEqual(handed[0]?.items.filter((item) => item.status === 'testing').map((item) => `${item.number} ${item.open ? 'open' : 'closed'}`).sort(), [numbers.proven, numbers.due, numbers.unlanded, numbers.unreadable, numbers.strangerProof, numbers.closed].map((number) => `${number} ${number === numbers.closed ? 'closed' : 'open'}`).sort());
    assert.equal(handed[0]?.board, 'o/forgejo');
    assert.ok(!(handed[0]?.records ?? []).some((record) => record.number === numbers.closed || record.number === numbers.implementing));
  });

  it('shows no block where the listed issues hold no open issue in testing, and none for --json', async () => {
    const { result: onlyImplementing } = await run(['o/one', '--label', 'status/implementing']);
    assert.equal(handed.length, 0);
    assert.ok(!onlyImplementing.stdout.includes('THE BLOCK'));
    const { result: json } = await run(['o/one', '--json']);
    assert.equal(handed.length, 0);
    assert.doesNotThrow(() => JSON.parse(json.stdout));
  });

  it('names a block that could not be made', async () => {
    const harness = createRecordingHarness();
    harness.failing.add('readTestingPage');
    await assert.rejects(status.run(['o/one'], contextFor(fake, { harness })), (error: unknown) => error instanceof PreconditionError && /the testing block of status could not be made: planted: readTestingPage failed/.test(error.message));
  });
});
