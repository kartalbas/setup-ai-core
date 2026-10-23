import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, describe, it } from 'node:test';
import { PartialCompletionError } from '../api/client.mts';
import { clientFor, startFakeForgejo } from '../testing/fake-forgejo.mts';
import type { FakeForgejo } from '../testing/fake-forgejo.mts';
import { getIssue } from './issues.mts';
import { applyLabelChange, applySync, builtInLabels, canonicalLabelName, familyOf, listOrganizationLabels, parseCatalog, planLabelChange, planSync, replaceFamilyLabel } from './labels.mts';
import { UsageError } from './refusals.mts';

describe('the families', () => {
  it('are the labels with exactly one slash and a known group', () => {
    assert.equal(familyOf('status/ready')?.exclusive, true);
    assert.equal(familyOf('area/gate')?.exclusive, false);
    assert.equal(familyOf('area/foo/bar'), undefined);
    assert.equal(familyOf('needs:owner'), undefined);
    assert.equal(familyOf('engine:approved'), undefined);
    assert.equal(familyOf('unknown/thing'), undefined);
  });

  it('write group:name as group/name for the families only', () => {
    assert.equal(canonicalLabelName('type:bug'), 'type/bug');
    assert.equal(canonicalLabelName('area:gate'), 'area/gate');
    assert.equal(canonicalLabelName('closes:test'), 'closes:test');
    assert.equal(canonicalLabelName('closes:machine'), 'closes:machine');
    assert.equal(canonicalLabelName('needs:owner'), 'needs:owner');
    assert.equal(canonicalLabelName('engine:approved'), 'engine:approved');
    assert.equal(canonicalLabelName('type/bug'), 'type/bug');
  });
});

describe('the catalog', () => {
  it('reads every row of the template that ships with the harness', () => {
    const text = readFileSync(new URL('../../../../templates/.ai-core/labels.tsv', import.meta.url), 'utf8');
    const labels = parseCatalog(text, 'labels.tsv');
    assert.ok(labels.length > 30);
    assert.ok(labels.some((label) => label.name === 'type/bug' && label.exclusive));
    assert.ok(labels.some((label) => label.name === 'area/gate' && !label.exclusive));
    assert.ok(labels.some((label) => label.name === 'closes:test'));
    assert.ok(labels.some((label) => label.name === 'needs:owner'));
  });

  it('refuses a bad row and names its line (planted: a bad last row)', () => {
    const good = 'type\ttype:bug\tD73A4A\tA bug\n';
    parseCatalog(good, 'f');
    assert.throws(() => parseCatalog(`${good}area\tarea:x\tZZZZZZ\tText\n`, 'f'), /f:2 has 'ZZZZZZ'/);
    assert.throws(() => parseCatalog(`${good}area\ttype:x\t112233\tText\n`, 'f'), /f:2 is in group 'area' but is named 'type:x'/);
    assert.throws(() => parseCatalog(`${good}nope\tnope:x\t112233\tText\n`, 'f'), UsageError);
    assert.throws(() => parseCatalog(`${good}type\ttype:bug\t112233\tAgain\n`, 'f'), /a second time/);
    assert.throws(() => parseCatalog(`${good}type\ttype:y\t112233\n`, 'f'), /no description/);
  });

  it('holds the status/ and priority/ constants', () => {
    const names = builtInLabels().map((label) => label.name);
    assert.ok(names.includes('status/not-planned') && names.includes('priority/p9'));
    assert.ok(builtInLabels().every((label) => label.exclusive));
  });

  it('plans no write for a catalog the organization already holds (innocent) and one write for one difference (planted)', () => {
    const wanted = [{ name: 'type/bug', color: 'd73a4a', description: 'A bug', exclusive: true }];
    const same = [{ id: 1, name: 'type/bug', color: 'D73A4A', description: 'A bug', exclusive: true }];
    const plan = planSync(wanted, same);
    assert.equal(plan.create.length + plan.update.length, 0);
    assert.equal(plan.unchanged, 1);
    const different = planSync(wanted, [{ id: 1, name: 'type/bug', color: 'd73a4a', description: 'Other', exclusive: false }]);
    assert.deepEqual(different.update.map((entry) => [entry.id, Object.keys(entry.changes).sort()]), [[1, ['description', 'exclusive']]]);
    assert.deepEqual(planSync(wanted, [...same, { id: 2, name: 'stray', color: 'aaaaaa', description: undefined, exclusive: undefined }]).leftAlone, ['stray']);
  });
});

describe('planning a label change', () => {
  const current = ['status/ready', 'area/gate', 'needs:owner'];

  it('replaces one family and keeps every other label (innocent case)', () => {
    assert.deepEqual(planLabelChange(current, { replace: ['status/testing'] }), { add: ['status/testing'], remove: ['status/ready'] });
  });

  it('replaces a non-exclusive family as a set', () => {
    assert.deepEqual(planLabelChange(current, { replace: ['area/docs', 'area/tests'] }), { add: ['area/docs', 'area/tests'], remove: ['area/gate'] });
  });

  it('reads type:bug as type/bug', () => {
    assert.deepEqual(planLabelChange([], { add: ['type:bug'] }), { add: ['type/bug'], remove: [] });
  });

  it('refuses two labels of one exclusive family (planted)', () => {
    assert.throws(() => planLabelChange([], { add: ['type/bug', 'type/feature'] }), /exclusive family type\//);
    assert.throws(() => planLabelChange([], { replace: ['status/ready', 'status/testing'] }), UsageError);
  });

  it('refuses an add that would make a second label of an exclusive family, and says how', () => {
    assert.throws(() => planLabelChange(current, { add: ['status/testing'] }), /use --replace/);
  });

  it('allows two labels of the non-exclusive family', () => {
    assert.deepEqual(planLabelChange(current, { add: ['area/docs'] }), { add: ['area/docs'], remove: [] });
  });

  it('changes nothing for a label already there or not there', () => {
    assert.deepEqual(planLabelChange(current, { add: ['area/gate'], remove: ['type/bug'] }), { add: [], remove: [] });
  });

  it('refuses contradictory and empty requests', () => {
    assert.throws(() => planLabelChange(current, { add: ['area/docs'], remove: ['area/docs'] }), /both added and removed/);
    assert.throws(() => planLabelChange(current, { replace: ['area/docs'], add: ['area/tests'] }), UsageError);
    assert.throws(() => planLabelChange(current, {}), UsageError);
  });
});

describe('changing the labels of an issue against the fake', () => {
  let fake: FakeForgejo;
  const ref = { owner: 'o', repo: 'r', number: 1 };
  before(async () => {
    fake = await startFakeForgejo();
    fake.addRepository('o/r');
    for (const name of ['status/ready', 'status/testing', 'type/bug']) fake.addLabel('o', { name, exclusive: true });
    for (const name of ['area/gate', 'area/docs', 'needs:owner']) fake.addLabel('o', { name });
    fake.addIssue('o/r', { title: 'First, so that there is one', labels: ['status/ready', 'area/gate', 'needs:owner'] });
  });
  after(async () => {
    await fake.close();
  });

  it('replaces the status and leaves the other labels, without a PUT', async () => {
    const api = clientFor(fake);
    const issue = await getIssue(api, ref);
    const after = await replaceFamilyLabel(api, ref, issue, 'status/testing');
    assert.deepEqual([...after].sort(), ['area/gate', 'needs:owner', 'status/testing']);
    assert.ok(fake.requests.every((request) => request.method !== 'PUT'));
    assert.ok(fake.requests.some((request) => request.method === 'POST' && request.path.endsWith('/labels')));
  });

  it('changes nothing and writes nothing when the family already holds the value (innocent case)', async () => {
    const api = clientFor(fake);
    const before = fake.writes().length;
    await replaceFamilyLabel(api, ref, await getIssue(api, ref), 'status/testing');
    assert.equal(fake.writes().length, before);
  });

  it('removes a label that Forgejo did not remove by itself, when the label is not flagged exclusive', async () => {
    fake.addLabel('o', { name: 'goal/a' });
    fake.addLabel('o', { name: 'goal/b' });
    const api = clientFor(fake);
    await applyLabelChange(api, ref, await getIssue(api, ref), planLabelChange([], { add: ['goal/a'] }));
    const issue = await getIssue(api, ref);
    const after = await applyLabelChange(api, ref, issue, { add: ['goal/b'], remove: ['goal/a'] });
    assert.deepEqual([...after].filter((name) => name.startsWith('goal/')), ['goal/b']);
  });

  it('refuses an unknown label before it writes anything', async () => {
    const api = clientFor(fake);
    const writes = fake.writes().length;
    await assert.rejects(applyLabelChange(api, ref, await getIssue(api, ref), { add: ['area/nonexistent'], remove: [] }), /has no label area\/nonexistent: add it to labels.tsv and run labels-sync --org o/);
    assert.equal(fake.writes().length, writes);
  });

  it('reports a removal that failed after an add as a partial completion', async () => {
    fake.addLabel('o', { name: 'area/second' });
    const api = clientFor(fake);
    const issue = await getIssue(api, ref);
    fake.fail({ method: 'DELETE', path: /\/labels\//, mode: { kind: 'status', status: 500, message: 'planted' } });
    await assert.rejects(applyLabelChange(api, ref, issue, { add: ['area/second'], remove: ['area/gate'] }), (error: unknown) => error instanceof PartialCompletionError && /added area\/second/.test(error.message));
  });

  it('creates and updates organization labels, and the second run writes nothing', async () => {
    const api = clientFor(fake);
    const desired = [{ name: 'type/chore', color: 'fef2c0', description: 'Upkeep', exclusive: true }];
    await applySync(api, 'o', planSync(desired, await listOrganizationLabels(api, 'o')));
    assert.ok(fake.listLabels('o').some((label) => label.name === 'type/chore' && label.exclusive));
    const writes = fake.writes().length;
    await applySync(api, 'o', planSync(desired, await listOrganizationLabels(api, 'o')));
    assert.equal(fake.writes().length, writes);
  });
});
