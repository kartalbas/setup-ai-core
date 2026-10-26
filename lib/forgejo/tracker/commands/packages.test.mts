import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { after, before, describe, it } from 'node:test';
import { pathToFileURL } from 'node:url';
import { PartialCompletionError } from '../api/client.mts';
import { issueShape } from '../api/shapes.mts';
import { listOrganizationLabels } from '../domain/labels.mts';
import { PreconditionError, UsageError } from '../domain/refusals.mts';
import { composeProvenRecord } from '../domain/workflow.mts';
import { clientFor, contextFor, seedLabels, startFakeForgejo } from '../testing/fake-forgejo.mts';
import type { FakeForgejo, FakeOptions } from '../testing/fake-forgejo.mts';
import { createGitFixture } from '../testing/git-fixture.mts';
import { plantedCopy } from '../testing/planted-copy.mts';
import type { GitFixture } from '../testing/git-fixture.mts';
import type { CommandContext } from './command.mts';
import * as issueLabel from './issue-label.mts';
import * as issuePackage from './issue-package.mts';
import * as issueState from './issue-state.mts';
import * as labelsSync from './labels-sync.mts';

const TRACKER_DIRECTORY = resolve(import.meta.dirname, '..');
const HARNESS = resolve(TRACKER_DIRECTORY, '../../..');
const SKILL = join(HARNESS, 'skills/person-in-charge/SKILL.md');
const WORKFLOW = join(HARNESS, 'tests/package-workflow.mjs');
const scratch = mkdtempSync(join(tmpdir(), 'forgejo-packages-'));
const binary = join(scratch, 'bin');
let fixture: GitFixture;
let checkout: string;
const fakes: FakeForgejo[] = [];

before(() => {
  execFileSync('mkdir', ['-p', binary]);
  writeFileSync(join(binary, 'ai-core'), `#!/bin/sh\nexec bash "${HARNESS}/bin/ai-core" "$@"\n`);
  chmodSync(join(binary, 'ai-core'), 0o755);
  fixture = createGitFixture();
  checkout = fixture.clone(fixture.createRemote('example-org', 'shop'), 'project', 'shop');
});
after(async () => {
  for (const fake of fakes) await fake.close();
  fixture.dispose();
  rmSync(scratch, { recursive: true, force: true });
});

const SHOP5 = 'example-org/shop#5';
const API7 = 'example-org/api#7';
const LIB4 = 'other-org/lib#4';
const NAME = 'package/shop#5';
const ISSUES = { 'example-org/shop': 8, 'example-org/api': 8, 'example-org/plans': 9, 'other-org/lib': 4 } as const;

interface World {
  readonly fake: FakeForgejo;
  readonly context: CommandContext;
}
interface Modules {
  readonly startFakeForgejo: typeof startFakeForgejo;
  readonly seedLabels: typeof seedLabels;
  readonly contextFor: typeof contextFor;
  readonly run: typeof issuePackage.run;
}
const REAL: Modules = { startFakeForgejo, seedLabels, contextFor, run: issuePackage.run };

// Two organizations, three repositories in the first and one in the second, every issue open and in implementation.
async function world(options: FakeOptions = {}, modules: Modules = REAL): Promise<World> {
  const fake = await modules.startFakeForgejo(options);
  fakes.push(fake);
  for (const full of Object.keys(ISSUES)) fake.addRepository(full);
  modules.seedLabels(fake, 'example-org');
  modules.seedLabels(fake, 'other-org');
  for (const [full, count] of Object.entries(ISSUES)) {
    for (let number = 1; number <= count; number++) fake.addIssue(full, { title: `Issue ${number} of ${full}, so that it has a number`, labels: ['status/implementing', 'type/feature', 'area/gate'] });
  }
  return { fake, context: modules.contextFor(fake, { cwd: checkout }) };
}

function flags(members: readonly string[], removals: readonly string[]): string[] {
  return [...members.flatMap((member) => ['--member', member]), ...removals.flatMap((removal) => ['--remove', removal])];
}

interface Outcome {
  readonly status: number | null;
  readonly stdout: string;
  readonly stderr: string;
}

function shell(command: string, environment: Record<string, string>): Promise<Outcome> {
  return new Promise((resolveOutcome) => {
    const child = spawn('bash', ['-c', command], { cwd: scratch, env: { PATH: `${binary}:${process.env.PATH ?? ''}`, HOME: scratch, ...environment } });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk: Buffer) => (stdout += chunk.toString()));
    child.stderr.on('data', (chunk: Buffer) => (stderr += chunk.toString()));
    child.on('close', (status) => resolveOutcome({ status, stdout, stderr }));
  });
}

// The command exactly as the coordinator's skill writes it, filled in.
function commandOf(skill: string, anchor: string, members: readonly string[], removals: readonly string[]): string {
  return execFileSync('node', [WORKFLOW, skill, anchor, ...flags(members, removals)], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

// That command, run through bin/ai-core against the fake.
function coordinator(w: World, anchor: string, members: readonly string[], removals: readonly string[] = []): Promise<Outcome> {
  return shell(commandOf(SKILL, anchor, members, removals), { TRACKER: 'forgejo', FORGEJO_URL: w.fake.url, FORGEJO_TOKEN_COMMAND: `printf '%s' ${w.fake.token}` });
}

function direct(w: World, anchor: string, members: readonly string[], removals: readonly string[] = [], run: typeof issuePackage.run = issuePackage.run) {
  const [repository, number] = anchor.split('#');
  return run([repository ?? '', number ?? '', ...flags(members, removals)], w.context);
}

const modulesOf = async (copy: string): Promise<Modules> => {
  const fakeModule = (await import(pathToFileURL(join(copy, 'testing/fake-forgejo.mts')).href)) as typeof import('../testing/fake-forgejo.mts');
  const commandModule = (await import(pathToFileURL(join(copy, 'commands/issue-package.mts')).href)) as typeof issuePackage;
  return { startFakeForgejo: fakeModule.startFakeForgejo, seedLabels: fakeModule.seedLabels, contextFor: fakeModule.contextFor, run: commandModule.run };
};

function split(ref: string): { full: string; number: number } {
  const [full = '', number = ''] = ref.split('#');
  return { full, number: Number(number) };
}

const labelsOfIssue = (w: World, ref: string): string[] => w.fake.readIssue(split(ref).full, split(ref).number).labels.sort();
const packageLabelsOf = (w: World, ref: string): string[] => labelsOfIssue(w, ref).filter((label) => label.startsWith('package/'));
const withoutPackage = (labels: readonly string[]): string[] => labels.filter((label) => !label.startsWith('package/'));
const labelOf = (w: World, owner: string, name = NAME) => w.fake.listLabels(owner).find((label) => label.name === name);
const writesOf = (w: World): number => w.fake.writes().length;

// What the tracker's own filter finds for a label name in one organization, every issue state, as repository#number.
async function filterBy(w: World, owner: string, name: string): Promise<string[]> {
  assert.ok(labelOf(w, owner, name) !== undefined, `${owner} has no label ${name} to filter by`);
  const found = await clientFor(w.fake).callAll({ name: 'filter', path: '/repos/issues/search', query: { type: 'issues', state: 'all', owner, labels: name }, readItem: issueShape.type.read });
  return found.map((issue) => `${issue.repository?.full_name ?? ''}#${issue.number}`).sort();
}

async function filterEverywhere(w: World, name: string): Promise<string[]> {
  const found: string[] = [];
  for (const owner of ['example-org', 'other-org']) if (labelOf(w, owner, name) !== undefined) found.push(...(await filterBy(w, owner, name)));
  return found.sort();
}

// The state a whole package must be left in: the filter lists exactly the members, each carries this one package label, and each
// organization has one exclusive label of the name, archived or active as asked.
async function assertPackage(w: World, name: string, members: readonly string[], archived?: boolean): Promise<void> {
  assert.deepEqual(await filterEverywhere(w, name), [...members].sort());
  for (const member of members) assert.deepEqual(packageLabelsOf(w, member), [name], member);
  for (const owner of new Set(members.map((member) => split(member).full.split('/')[0] ?? ''))) {
    const same = w.fake.listLabels(owner).filter((label) => label.name === name);
    assert.equal(same.length, 1, `${owner} holds ${same.length} labels named ${name}`);
    assert.equal(same[0]?.exclusive, true);
    if (archived !== undefined) assert.equal(same[0]?.archived, archived, `${owner}: archived`);
  }
}

async function complete(w: World, ref: string): Promise<void> {
  const { full, number } = split(ref);
  w.fake.addComment(full, number, 'fake-user', composeProvenRecord('prod', 'seen on production'));
  await issueState.runClose([full, String(number), '--reason', 'completed'], w.context);
}

const reopen = (w: World, ref: string): Promise<unknown> => issueState.runReopen([split(ref).full, String(split(ref).number), '--status', 'testing'], w.context);

describe('the coordinator workflow of SKILL.md labels a package', () => {
  it('puts one filterable label on every member of two repositories and on nothing else', async () => {
    const w = await world();
    const outside = labelsOfIssue(w, 'example-org/shop#6');
    const plan = labelsOfIssue(w, 'example-org/plans#9');
    const before = labelsOfIssue(w, SHOP5);
    const outcome = await coordinator(w, SHOP5, [SHOP5, API7]);
    assert.equal(outcome.status, 0, outcome.stderr);
    assert.match(outcome.stdout, /package\/shop#5: 2 members confirmed, 0 departures confirmed, 0 of 2 members complete/);
    await assertPackage(w, NAME, [API7, SHOP5], false);
    assert.deepEqual(await filterBy(w, 'example-org', NAME), [API7, SHOP5]);
    assert.deepEqual(labelsOfIssue(w, 'example-org/shop#6'), outside);
    assert.deepEqual(labelsOfIssue(w, 'example-org/plans#9'), plan);
    assert.deepEqual(withoutPackage(labelsOfIssue(w, SHOP5)), before);
    assert.equal(labelOf(w, 'example-org')?.description, 'Package anchored at example-org/shop#5');
  });

  it('goes red when a member of the second repository is left without the label (planted) and stays green for the issue outside (innocent)', async () => {
    const w = await world();
    assert.equal((await coordinator(w, SHOP5, [SHOP5])).status, 0);
    await assert.rejects(assertPackage(w, NAME, [SHOP5, API7]), /expected|deepEqual|Expected/);
    assert.deepEqual(packageLabelsOf(w, 'example-org/shop#6'), []);
    assert.equal((await coordinator(w, SHOP5, [SHOP5, API7])).status, 0);
    await assertPackage(w, NAME, [SHOP5, API7]);
  });

  it('goes red where the command itself skips the member of the second repository (planted in a copy of the tracker)', async () => {
    const copy = plantedCopy([['commands/issue-package.mts', 'for (const ref of scope.members) {\n      const fresh', 'for (const ref of scope.members.slice(0, 1)) {\n      const fresh']]);
    const modules = await modulesOf(copy);
    const w = await world({}, modules);
    await direct(w, SHOP5, [SHOP5, API7], [], modules.run).catch(() => undefined);
    await assert.rejects(assertPackage(w, NAME, [SHOP5, API7]), /expected|deepEqual|Expected/);
    assert.deepEqual(packageLabelsOf(w, 'example-org/shop#6'), []);
  });

  it('keeps issues of one number in different repositories apart', async () => {
    const w = await world();
    assert.equal((await coordinator(w, SHOP5, [SHOP5, 'example-org/api#5'])).status, 0);
    await assertPackage(w, NAME, ['example-org/api#5', SHOP5]);
    assert.deepEqual(packageLabelsOf(w, 'example-org/api#6'), []);
    assert.deepEqual(packageLabelsOf(w, 'example-org/shop#6'), []);
  });

  it('names the label after the first issue whatever the order of the members', async () => {
    const w = await world();
    assert.equal((await coordinator(w, SHOP5, [API7, SHOP5])).status, 0);
    await assertPackage(w, NAME, [API7, SHOP5]);
    assert.equal(w.fake.listLabels('example-org').filter((label) => label.name.startsWith('package/')).length, 1);
  });

  it('reads the command out of the skill, and goes red where the skill drifted (planted: another command name, another option)', () => {
    assert.match(commandOf(SKILL, SHOP5, [SHOP5, API7], [LIB4]), /^ai-core issue-package 'example-org\/shop' 5 --member 'example-org\/shop#5' --member 'example-org\/api#7' --remove 'other-org\/lib#4'$/);
    const text = readFileSync(SKILL, 'utf8');
    const plant = (name: string, from: string, to: string): string => {
      assert.ok(text.includes(from), `the plant did not take: ${from}`);
      const path = join(scratch, `${name}.md`);
      writeFileSync(path, text.replace(from, to));
      return path;
    };
    assert.throws(() => commandOf(plant('renamed', 'ai-core issue-package <first issue', 'ai-core issue-packages <first issue'), SHOP5, [SHOP5], []), /holds no command line/);
    assert.throws(() => commandOf(plant('option', '--member <OWNER/REPO#NUMBER> ...', '--members <OWNER/REPO#NUMBER> ...'), SHOP5, [SHOP5], []), /a placeholder is left/);
    assert.throws(() => commandOf(plant('departures', '[--remove <OWNER/REPO#NUMBER> ...]', '[--drop <OWNER/REPO#NUMBER> ...]'), SHOP5, [SHOP5], [API7]), /a placeholder is left/);
  });
});

describe('membership changes and restart', () => {
  it('adds a later member, and takes a departure off by the previous membership', async () => {
    const w = await world();
    assert.equal((await coordinator(w, SHOP5, [SHOP5, API7])).status, 0);
    assert.equal((await coordinator(w, SHOP5, [SHOP5, API7, 'example-org/shop#8'])).status, 0);
    await assertPackage(w, NAME, ['example-org/shop#8', API7, SHOP5]);
    const apiBefore = withoutPackage(labelsOfIssue(w, API7));
    assert.equal((await coordinator(w, SHOP5, [SHOP5, 'example-org/shop#8'], [API7])).status, 0);
    await assertPackage(w, NAME, ['example-org/shop#8', SHOP5]);
    assert.deepEqual(labelsOfIssue(w, API7), apiBefore);
  });

  it('leaves a member that moved to another package with that package label only, and an old departure does not take it off', async () => {
    const w = await world();
    assert.equal((await coordinator(w, SHOP5, [SHOP5, 'example-org/shop#8'])).status, 0);
    assert.equal((await coordinator(w, 'example-org/api#2', ['example-org/api#2', 'example-org/shop#8'])).status, 0);
    assert.deepEqual(packageLabelsOf(w, 'example-org/shop#8'), ['package/api#2']);
    assert.deepEqual(await filterBy(w, 'example-org', NAME), [SHOP5]);
    const replayed = await coordinator(w, SHOP5, [SHOP5], ['example-org/shop#8']);
    assert.equal(replayed.status, 0, replayed.stderr);
    assert.deepEqual(packageLabelsOf(w, 'example-org/shop#8'), ['package/api#2']);
    assert.deepEqual(await filterBy(w, 'example-org', 'package/api#2'), ['example-org/api#2', 'example-org/shop#8']);
  });

  const phaseLine = `PHASE area: build | you | order not set | selected claude m high | plans 1 | reviews 0 | context fit | next | package ${SHOP5} | members ${SHOP5}, ${API7}, ${LIB4} | previous ${SHOP5}, ${API7}, example-org/shop#8`;
  const recorded = (line: string): { anchor: string; members: string[]; removals: string[] } => {
    const field = (key: string): string[] => {
      const value = line.split(' | ').find((part) => part.startsWith(`${key} `))?.slice(key.length + 1) ?? 'none';
      return value === 'none' ? [] : value.split(', ');
    };
    const members = field('members');
    return { anchor: field('package')[0] ?? '', members, removals: field('previous').filter((ref) => !members.includes(ref)) };
  };

  it('restarts from the recorded PHASE line with the plan issue elsewhere, and a second run writes nothing', async () => {
    const w = await world();
    assert.equal((await coordinator(w, SHOP5, [SHOP5, API7, 'example-org/shop#8'])).status, 0);
    const request = recorded(phaseLine);
    assert.deepEqual(request.removals, ['example-org/shop#8']);
    assert.equal((await coordinator(w, request.anchor, request.members, request.removals)).status, 0);
    await assertPackage(w, NAME, [API7, LIB4, SHOP5]);
    assert.deepEqual(packageLabelsOf(w, 'example-org/shop#8'), []);
    assert.deepEqual(packageLabelsOf(w, 'example-org/plans#9'), []);
    const writes = writesOf(w);
    assert.equal((await coordinator(w, request.anchor, request.members, request.removals)).status, 0);
    assert.equal(writesOf(w), writes);
  });

  it('keeps the label of the first issue when that issue leaves the package', async () => {
    const w = await world();
    assert.equal((await coordinator(w, SHOP5, [SHOP5, API7])).status, 0);
    assert.equal((await coordinator(w, SHOP5, [API7, 'example-org/api#2'], [SHOP5])).status, 0);
    assert.equal(w.fake.listLabels('example-org').filter((label) => label.name.startsWith('package/')).length, 1);
    await assertPackage(w, NAME, ['example-org/api#2', API7]);
    assert.deepEqual(packageLabelsOf(w, SHOP5), []);
  });

  it('refuses before the first write: a foreign label of the name, one that names no anchor, a malformed or overlapping request, a missing issue, an unreadable repository', async () => {
    const w = await world();
    w.fake.addLabel('example-org', { name: NAME, description: 'Package anchored at other-org/shop#5', exclusive: true });
    let writes = writesOf(w);
    const foreign = await coordinator(w, SHOP5, [SHOP5, API7]);
    assert.equal(foreign.status, 2);
    assert.match(foreign.stderr, /anchored at example-org\/shop#5/);
    assert.match(foreign.stderr, /names the anchor other-org\/shop#5/);
    assert.equal(writesOf(w), writes);
    assert.deepEqual(packageLabelsOf(w, SHOP5), []);

    const v = await world();
    v.fake.addLabel('example-org', { name: NAME, description: 'nobody', exclusive: true });
    writes = writesOf(v);
    const anonymous = await coordinator(v, SHOP5, [SHOP5]);
    assert.equal(anonymous.status, 2);
    assert.match(anonymous.stderr, /names no anchor/);
    assert.equal(writesOf(v), writes);

    const x = await world();
    writes = writesOf(x);
    assert.equal((await coordinator(x, SHOP5, ['shop#5'])).status, 2);
    assert.equal((await coordinator(x, SHOP5, [SHOP5, API7], [API7])).status, 2);
    assert.equal((await coordinator(x, SHOP5, [SHOP5, SHOP5])).status, 2);
    await assert.rejects(direct(x, SHOP5, []), UsageError);
    const missing = await coordinator(x, SHOP5, [SHOP5, 'example-org/api#99']);
    assert.equal(missing.status, 3);
    assert.match(missing.stderr, /example-org\/api#99/);
    x.fake.fail({ method: 'GET', path: '/repos/example-org/api/labels', mode: { kind: 'status', status: 500, message: 'planted' } });
    const unreadable = await coordinator(x, SHOP5, [SHOP5, API7]);
    assert.equal(unreadable.status, 3);
    assert.equal(writesOf(x), writes);
    assert.equal(x.fake.listLabels('example-org').some((label) => label.name === NAME), false);
  });

  it('reuses the archived label of the package own first issue (innocent) and makes it active for a member that is open', async () => {
    const w = await world();
    const id = w.fake.addLabel('example-org', { name: NAME, description: 'Package anchored at example-org/shop#5', exclusive: true, archived: true });
    const outcome = await coordinator(w, SHOP5, [SHOP5, API7]);
    assert.equal(outcome.status, 0, outcome.stderr);
    await assertPackage(w, NAME, [API7, SHOP5], false);
    assert.equal((await listOrganizationLabels(clientFor(w.fake), 'example-org')).find((label) => label.name === NAME)?.id, id);
  });

  it('leaves the ordinary labels of an issue to issue-label, and the package label with them (innocent)', async () => {
    const w = await world();
    assert.equal((await coordinator(w, SHOP5, [SHOP5, API7])).status, 0);
    await issueLabel.runLabel(['example-org/shop', '5', '--add', 'area:docs', '--remove', 'area:gate'], w.context);
    await issueLabel.runLabel(['example-org/shop', '5', '--replace', 'type:bug'], w.context);
    assert.deepEqual(labelsOfIssue(w, SHOP5), ['area/docs', NAME, 'status/implementing', 'type/bug']);
  });
});

describe('creation, API scope and the label catalog', () => {
  it('shares one exclusive organization label between the repositories of an organization, and gives each organization its own', async () => {
    const w = await world();
    assert.equal((await coordinator(w, SHOP5, [SHOP5, API7, LIB4])).status, 0);
    for (const owner of ['example-org', 'other-org']) assert.equal(w.fake.listLabels(owner).filter((label) => label.name === NAME).length, 1, owner);
    await assertPackage(w, NAME, [API7, LIB4, SHOP5]);
    const creations = w.fake.requests.filter((request) => request.method === 'POST' && /^\/orgs\/[^/]+\/labels$/.test(request.path));
    assert.deepEqual(creations.map((request) => request.path).sort(), ['/orgs/example-org/labels', '/orgs/other-org/labels']);
  });

  it('finds its label on a later page of the organization labels and creates no second one', async () => {
    const w = await world({ pageMaximum: 5 });
    assert.equal((await coordinator(w, SHOP5, [SHOP5])).status, 0);
    const position = w.fake.listLabels('example-org').findIndex((label) => label.name === NAME);
    assert.ok(position >= 5, `the label stands at ${position}, on the first page`);
    assert.equal((await coordinator(w, SHOP5, [SHOP5, API7])).status, 0);
    assert.equal(w.fake.requests.filter((request) => request.method === 'POST' && request.path === '/orgs/example-org/labels').length, 1);
    await assertPackage(w, NAME, [API7, SHOP5]);
  });

  it('takes a failed later page for an error and writes nothing, never for a label that is not there', async () => {
    const w = await world({ pageMaximum: 5 });
    assert.equal((await coordinator(w, SHOP5, [SHOP5])).status, 0);
    const writes = writesOf(w);
    w.fake.fail({ method: 'GET', path: '/orgs/example-org/labels', skip: 1, mode: { kind: 'status', status: 500, message: 'planted' } });
    const outcome = await coordinator(w, SHOP5, [SHOP5, API7]);
    assert.equal(outcome.status, 3);
    assert.match(outcome.stderr, /page 2/);
    assert.equal(writesOf(w), writes);
  });

  it('refuses where a repository has its own label of the name, before any write', async () => {
    const w = await world();
    w.fake.addRepositoryLabel('example-org/api', { name: NAME, exclusive: true });
    const writes = writesOf(w);
    const outcome = await coordinator(w, SHOP5, [SHOP5, API7]);
    assert.equal(outcome.status, 2);
    assert.match(outcome.stderr, /example-org\/api has its own label package\/shop#5/);
    assert.equal(writesOf(w), writes);
  });

  it('survives labels-sync before and after the archival, which touches neither the label nor its members', async () => {
    const w = await world();
    const sync = (): Promise<unknown> => labelsSync.run(['--org', 'example-org'], contextFor(w.fake, { settings: { forgejoUrl: w.fake.url, tokenCommand: `printf '%s' ${w.fake.token}`, labelsFile: join(HARNESS, 'templates/.ai-core/labels.tsv') } }));
    const snapshot = async (): Promise<unknown> => ({ label: (await listOrganizationLabels(clientFor(w.fake), 'example-org')).find((label) => label.name === NAME), members: await filterBy(w, 'example-org', NAME) });
    assert.equal((await coordinator(w, SHOP5, [SHOP5, API7])).status, 0);
    const active = await snapshot();
    await sync();
    assert.deepEqual(await snapshot(), active);
    await complete(w, SHOP5);
    await complete(w, API7);
    assert.equal((await coordinator(w, SHOP5, [SHOP5, API7])).status, 0);
    await assertPackage(w, NAME, [API7, SHOP5], true);
    const archived = await snapshot();
    await sync();
    assert.deepEqual(await snapshot(), archived);
  });

  it('takes a missing is_archived field for no archival (planted: the field is left out of every answer about the label)', async () => {
    const w = await world();
    assert.equal((await coordinator(w, SHOP5, [SHOP5])).status, 0);
    await complete(w, SHOP5);
    w.fake.fail({ method: 'PATCH', path: /^\/orgs\/example-org\/labels\//, mode: { kind: 'omit-field', field: 'is_archived' } });
    const outcome = await coordinator(w, SHOP5, [SHOP5]);
    assert.notEqual(outcome.status, 0);
    assert.match(outcome.stderr, /answered is_archived undefined where true was asked/);
    assert.doesNotMatch(outcome.stdout, /archived/);
    w.fake.fail({ method: 'GET', path: '/orgs/example-org/labels', mode: { kind: 'omit-field', field: 'is_archived' } });
    const unreadable = await coordinator(w, SHOP5, [SHOP5]);
    assert.equal(unreadable.status, 3);
    assert.match(unreadable.stderr, /did not say whether the label is archived/);
  });
});

describe('completion and revival', () => {
  it('keeps the labels active while a member is open, archives them with the last member, and makes them active again on a reopening', async () => {
    const w = await world();
    const members = [SHOP5, API7, LIB4];
    assert.equal((await coordinator(w, SHOP5, members)).status, 0);
    const ids = async (): Promise<number[]> => [
      (await listOrganizationLabels(clientFor(w.fake), 'example-org')).find((label) => label.name === NAME)?.id ?? -1,
      (await listOrganizationLabels(clientFor(w.fake), 'other-org')).find((label) => label.name === NAME)?.id ?? -1,
    ];
    const identity = await ids();
    await complete(w, SHOP5);
    assert.equal((await coordinator(w, SHOP5, members)).status, 0);
    await assertPackage(w, NAME, members, false);
    await complete(w, API7);
    assert.equal((await coordinator(w, SHOP5, members)).status, 0);
    await assertPackage(w, NAME, members, false);
    await complete(w, LIB4);
    const last = await coordinator(w, SHOP5, members);
    assert.equal(last.status, 0, last.stderr);
    assert.match(last.stdout, /example-org: package\/shop#5 is archived/);
    assert.match(last.stdout, /other-org: package\/shop#5 is archived/);
    assert.match(last.stdout, /3 of 3 members complete/);
    await assertPackage(w, NAME, members, true);
    for (const member of members) assert.equal(w.fake.readIssue(split(member).full, split(member).number).state, 'closed');
    const writes = writesOf(w);
    assert.equal((await coordinator(w, SHOP5, members)).status, 0);
    assert.equal(writesOf(w), writes);

    await reopen(w, API7);
    assert.equal((await coordinator(w, SHOP5, members)).status, 0);
    await assertPackage(w, NAME, members, false);
    assert.deepEqual(await ids(), identity);
    await assert.rejects(issueState.runClose(['example-org/api', '7', '--reason', 'completed'], w.context), PreconditionError);
    await complete(w, API7);
    assert.equal((await coordinator(w, SHOP5, members)).status, 0);
    await assertPackage(w, NAME, members, true);
  });

  it('does not archive for a member closed as not planned, one closed without status/done, or one that cannot be read', async () => {
    const w = await world();
    const members = [SHOP5, API7];
    assert.equal((await coordinator(w, SHOP5, members)).status, 0);
    await complete(w, SHOP5);
    await issueState.runClose(['example-org/api', '7', '--reason', 'not-planned'], w.context);
    assert.equal((await coordinator(w, SHOP5, members)).status, 0);
    await assertPackage(w, NAME, members, false);

    const v = await world();
    assert.equal((await coordinator(v, SHOP5, members)).status, 0);
    await complete(v, SHOP5);
    v.fake.removeLabel('example-org/api', 7, 'status/implementing');
    const closedWithoutStatus = split(API7);
    await issueState.runClose([closedWithoutStatus.full, String(closedWithoutStatus.number), '--reason', 'not-planned'], v.context);
    v.fake.removeLabel('example-org/api', 7, 'status/not-planned');
    assert.equal((await coordinator(v, SHOP5, members)).status, 0);
    await assertPackage(v, NAME, members, false);

    const x = await world();
    assert.equal((await coordinator(x, SHOP5, members)).status, 0);
    await complete(x, SHOP5);
    await complete(x, API7);
    x.fake.fail({ method: 'GET', path: '/repos/example-org/api/issues/7', times: 4, mode: { kind: 'status', status: 500, message: 'planted' } });
    const unreadable = await coordinator(x, SHOP5, members);
    assert.equal(unreadable.status, 3);
    await assertPackage(x, NAME, members, false);
  });

  // One member of each organization; only the one of the first is complete.
  const halfDone = async (modules: Modules): Promise<World> => {
    const w = await world({}, modules);
    await direct(w, SHOP5, [SHOP5, LIB4], [], modules.run);
    await complete(w, SHOP5);
    // a planted command may refuse after it archived: what it left behind is what is judged
    await direct(w, SHOP5, [SHOP5, LIB4], [], modules.run).catch(() => undefined);
    return w;
  };
  const assertBothActive = (w: World): void => {
    for (const owner of ['example-org', 'other-org']) assert.equal(labelOf(w, owner)?.archived, false, `${owner} archived while another organization has a member that is open`);
  };

  it('archives no label while a member of another organization is open (innocent); a planted per-organization completion archives it and is caught', async () => {
    assertBothActive(await halfDone(REAL));

    const copy = plantedCopy([['commands/issue-package.mts', 'const complete = isPackageComplete(confirmed);\n    const label = await attempt', 'const complete = isPackageComplete(confirmed.filter((issue) => issue.ref.owner === scope.owner));\n    const label = await attempt']]);
    const planted = await halfDone(await modulesOf(copy));
    assert.throws(() => assertBothActive(planted), /archived while another organization has a member that is open/);
  });

  it('refuses to call a label archived where the tracker kept nothing (planted: a Forgejo that ignores the archival and answers false)', async () => {
    const copy = plantedCopy([['testing/fake-forgejo.mts', "      if (typeof body.is_archived === 'boolean') label.archived = body.is_archived;\n", '']]);
    const modules = await modulesOf(copy);
    const w = await world({}, modules);
    await direct(w, SHOP5, [SHOP5], [], modules.run);
    await complete(w, SHOP5);
    await assert.rejects(direct(w, SHOP5, [SHOP5], [], modules.run), /answered is_archived false where true was asked/);
    assert.equal(labelOf(w, 'example-org')?.archived, false);
  });
});

describe('failure and concurrency', () => {
  it('converges when two identical classifications run at once, including the creation of the label', async () => {
    const w = await world();
    // one client, so that both runs ask in step and both read the organization labels before either creates one
    const results = await Promise.allSettled([direct(w, SHOP5, [SHOP5, API7]), direct(w, SHOP5, [SHOP5, API7])]);
    assert.deepEqual(results.map((result) => result.status), ['fulfilled', 'fulfilled']);
    const attempts = w.fake.requests.filter((request) => request.method === 'POST' && request.path === '/orgs/example-org/labels');
    assert.equal(attempts.length, 2, 'both runs tried to create the label, so the race was run');
    await assertPackage(w, NAME, [API7, SHOP5], false);
    for (const member of [SHOP5, API7]) assert.deepEqual(withoutPackage(labelsOfIssue(w, member)), ['area/gate', 'status/implementing', 'type/feature']);
  });

  it('converges when two runs reconcile at once after a member joined and after the last member completed', async () => {
    const w = await world();
    assert.equal((await coordinator(w, SHOP5, [SHOP5, API7])).status, 0);
    const joined = await Promise.all([coordinator(w, SHOP5, [SHOP5, API7, LIB4]), coordinator(w, SHOP5, [SHOP5, API7, LIB4])]);
    for (const outcome of joined) assert.ok(outcome.status === 0 || outcome.status === 3 || outcome.status === 4, outcome.stderr);
    assert.equal((await coordinator(w, SHOP5, [SHOP5, API7, LIB4])).status, 0);
    await assertPackage(w, NAME, [API7, LIB4, SHOP5], false);
    for (const member of [SHOP5, API7, LIB4]) await complete(w, member);
    const finished = await Promise.all([coordinator(w, SHOP5, [SHOP5, API7, LIB4]), coordinator(w, SHOP5, [SHOP5, API7, LIB4])]);
    for (const outcome of finished) assert.ok(outcome.status === 0 || outcome.status === 3 || outcome.status === 4, outcome.stderr);
    assert.equal((await coordinator(w, SHOP5, [SHOP5, API7, LIB4])).status, 0);
    await assertPackage(w, NAME, [API7, LIB4, SHOP5], true);
  });

  it('names the partial progress of a refusal on the second repository and converges on the next run', async () => {
    const w = await world();
    w.fake.fail({ method: 'POST', path: '/repos/example-org/api/issues/7/labels', mode: { kind: 'status', status: 403, message: 'planted' } });
    const outcome = await coordinator(w, SHOP5, [SHOP5, API7]);
    assert.equal(outcome.status, 4);
    assert.match(outcome.stderr, /Done before it failed: .*labeled example-org\/shop#5/);
    assert.match(outcome.stderr, /labeled example-org\/api#7 failed/);
    assert.equal(outcome.stdout, '');
    assert.deepEqual(packageLabelsOf(w, API7), []);
    assert.equal((await coordinator(w, SHOP5, [SHOP5, API7])).status, 0);
    await assertPackage(w, NAME, [API7, SHOP5], false);
  });

  it('reports a write whose answer was lost as uncertain, and the next run reads the tracker and converges', async () => {
    const w = await world();
    w.fake.fail({ method: 'POST', path: '/repos/example-org/api/issues/7/labels', mode: { kind: 'drop-after' } });
    const outcome = await coordinator(w, SHOP5, [SHOP5, API7]);
    assert.equal(outcome.status, 4);
    assert.match(outcome.stderr, /the write may have happened/);
    assert.equal(outcome.stdout, '');
    assert.equal((await coordinator(w, SHOP5, [SHOP5, API7])).status, 0);
    await assertPackage(w, NAME, [API7, SHOP5], false);
  });

  it('refuses a read-back that finds another state than the one written, and claims no success', async () => {
    const w = await world();
    w.fake.fail({ method: 'POST', path: '/repos/example-org/api/issues/7/labels', mode: { kind: 'after', effect: () => w.fake.removeLabel('example-org/api', 7, NAME) } });
    const outcome = await coordinator(w, SHOP5, [SHOP5, API7]);
    assert.notEqual(outcome.status, 0);
    assert.match(outcome.stderr, /example-org\/api#7/);
    assert.equal(outcome.stdout, '');
    assert.equal((await coordinator(w, SHOP5, [SHOP5, API7])).status, 0);
    await assertPackage(w, NAME, [API7, SHOP5], false);
  });

  it('names what was done where a read fails after the first writes, as it does where a write fails, and converges on the next run', async () => {
    const w = await world();
    // the first read of the member of other-org comes before any write; the second, right before its label goes on, fails
    w.fake.fail({ method: 'GET', path: '/repos/other-org/lib/issues/4', skip: 1, mode: { kind: 'status', status: 500, message: 'planted' } });
    const reread = await coordinator(w, SHOP5, [SHOP5, LIB4]);
    assert.equal(reread.status, 4, reread.stderr);
    assert.match(reread.stderr, /reading other-org\/lib#4 failed/);
    assert.match(reread.stderr, /Done before it failed: .*labeled example-org\/shop#5/);
    assert.equal(reread.stdout, '');
    assert.equal((await coordinator(w, SHOP5, [SHOP5, LIB4])).status, 0);
    await assertPackage(w, NAME, [LIB4, SHOP5], false);

    const v = await world();
    // the fourth list of the labels of other-org is the one after both members were labeled and read back
    v.fake.fail({ method: 'GET', path: '/orgs/other-org/labels', skip: 3, mode: { kind: 'status', status: 500, message: 'planted' } });
    const readBack = await coordinator(v, SHOP5, [SHOP5, LIB4]);
    assert.equal(readBack.status, 4, readBack.stderr);
    assert.match(readBack.stderr, /reading package\/shop#5 of other-org back failed/);
    assert.match(readBack.stderr, /Done before it failed: .*labeled other-org\/lib#4/);
    assert.equal(readBack.stdout, '');
    assert.equal((await coordinator(v, SHOP5, [SHOP5, LIB4])).status, 0);
    await assertPackage(v, NAME, [LIB4, SHOP5], false);
  });

  it('names what was archived when the archival of the second organization fails, and finishes it on the next run', async () => {
    const w = await world();
    const members = [SHOP5, LIB4];
    assert.equal((await coordinator(w, SHOP5, members)).status, 0);
    await complete(w, SHOP5);
    await complete(w, LIB4);
    w.fake.fail({ method: 'PATCH', path: /^\/orgs\/other-org\/labels\//, mode: { kind: 'status', status: 500, message: 'planted' } });
    const outcome = await coordinator(w, SHOP5, members);
    assert.equal(outcome.status, 4);
    assert.match(outcome.stderr, /Done before it failed: .*archived package\/shop#5 in example-org/);
    assert.doesNotMatch(outcome.stdout + outcome.stderr, /every label/);
    assert.equal(labelOf(w, 'example-org')?.archived, true);
    assert.equal(labelOf(w, 'other-org')?.archived, false);
    assert.equal((await coordinator(w, SHOP5, members)).status, 0);
    await assertPackage(w, NAME, members, true);
  });

  it('leaves no package change as a partial completion where the first write failed (innocent: nothing was done)', async () => {
    const w = await world();
    w.fake.fail({ method: 'POST', path: '/orgs/example-org/labels', mode: { kind: 'status', status: 403, message: 'planted' } });
    await assert.rejects(direct(w, SHOP5, [SHOP5]), (error: unknown) => !(error instanceof PartialCompletionError));
    assert.deepEqual(packageLabelsOf(w, SHOP5), []);
  });
});
