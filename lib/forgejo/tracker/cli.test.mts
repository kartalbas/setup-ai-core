import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { after, before, describe, it } from 'node:test';
import { REFUSED_ON_FORGEJO } from './cli.mts';
import { FAKE_TOKEN, seedLabels, startFakeForgejo } from './testing/fake-forgejo.mts';
import type { FakeForgejo } from './testing/fake-forgejo.mts';

const CLI = resolve(import.meta.dirname, 'cli.mts');
const HARNESS_ROOT = resolve(import.meta.dirname, '../../..');
const work = mkdtempSync(join(tmpdir(), 'forgejo-cli-'));
after(() => rmSync(work, { recursive: true, force: true }));

interface Outcome {
  readonly status: number | null;
  readonly stdout: string;
  readonly stderr: string;
}

function run(command: string, args: readonly string[], environment: Record<string, string>, cwd = work): Promise<Outcome> {
  return new Promise((resolveOutcome) => {
    const child = spawn(command, args, { cwd, env: { PATH: process.env.PATH ?? '', HOME: work, ...environment } });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk: Buffer) => (stdout += chunk.toString()));
    child.stderr.on('data', (chunk: Buffer) => (stderr += chunk.toString()));
    child.on('close', (status) => resolveOutcome({ status, stdout, stderr }));
  });
}

const cli = (args: readonly string[], environment: Record<string, string> = {}): Promise<Outcome> => run('node', [CLI, ...args], environment);

describe('without credentials and network', () => {
  it('prints its version for the doctor', async () => {
    const outcome = await cli(['--version']);
    assert.equal(outcome.status, 0);
    assert.match(outcome.stdout, /^ai-core forgejo tracker \d+\.\d+\.\d+\n$/);
  });

  it('prints its help, and the help of every command it has', async () => {
    const top = await cli(['help']);
    assert.equal(top.status, 0);
    const commands = top.stdout.split('\n').filter((line) => line.startsWith('  ')).map((line) => line.trim());
    assert.ok(commands.length >= 16);
    for (const command of commands) {
      const outcome = await cli([command, '--help']);
      assert.equal(outcome.status, 0, command);
      assert.match(outcome.stdout, /^usage: /, command);
      assert.equal(outcome.stderr, '');
    }
  });
});

describe('the exit codes', () => {
  let fake: FakeForgejo;
  let environment: Record<string, string>;
  before(async () => {
    fake = await startFakeForgejo();
    fake.addRepository('o/r');
    seedLabels(fake, 'o');
    fake.addIssue('o/r', { title: 'First, so that there is one', labels: ['status/ready'] });
    fake.addIssue('o/r', { title: 'Second, so that there are two', labels: ['status/ready'] });
    environment = { TRACKER: 'forgejo', FORGEJO_URL: fake.url, FORGEJO_TOKEN_COMMAND: `printf '%s' ${fake.token}` };
  });
  after(async () => {
    await fake.close();
  });

  it('is 0 for a success', async () => {
    const outcome = await cli(['issue-thread', 'o/r', '1', '--json'], environment);
    assert.equal(outcome.status, 0, outcome.stderr);
    assert.equal((JSON.parse(outcome.stdout) as { number: number }).number, 1);
  });

  it('is 0 for issue-list, which prints one line an issue and nothing else', async () => {
    const outcome = await cli(['issue-list', 'o/r', '--search', 'second'], environment);
    assert.equal(outcome.status, 0, outcome.stderr);
    assert.equal(outcome.stdout, 'o/r#2\tready\t-\tSecond, so that there are two\n');
    assert.equal(outcome.stderr, '');
  });

  it('is 1 for a precondition that refuses', async () => {
    const outcome = await cli(['issue-close', 'o/r', '1'], environment);
    assert.equal(outcome.status, 1);
    assert.match(outcome.stderr, /^error: .*issue-proof/);
  });

  it('is 1 for issue-mine on an issue that is not mine, with the REFUSED line on stdout', async () => {
    const outcome = await cli(['issue-mine', 'o/r', '1'], environment);
    assert.equal(outcome.status, 1);
    assert.match(outcome.stdout, /^REFUSED: /);
  });

  it('is 2 for invalid input, for a missing setting and for another tracker', async () => {
    assert.equal((await cli(['issue-thread', 'o/r', 'x'], environment)).status, 2);
    assert.equal((await cli(['issue-thread', 'o/r', '1'], { ...environment, FORGEJO_URL: '' })).status, 2);
    const other = await cli(['issue-thread', 'o/r', '1'], { ...environment, TRACKER: 'github' });
    assert.equal(other.status, 2);
    assert.match(other.stderr, /TRACKER is 'github'/);
    assert.equal((await cli(['nonsense'], environment)).status, 2);
  });

  it('is 3 for an external failure: an issue that is not there, a token Forgejo refuses', async () => {
    const missing = await cli(['issue-thread', 'o/r', '99', '--json'], environment);
    assert.equal(missing.status, 3);
    assert.match(missing.stderr, /^error: read issue o\/r#99: /);
    const refused = await cli(['issue-thread', 'o/r', '1'], { ...environment, FORGEJO_TOKEN_COMMAND: "printf '%s' wrong" });
    assert.equal(refused.status, 3);
  });

  it('is 4 for an action that partly completed, and says what was done', async () => {
    fake.fail({ method: 'PATCH', path: '/repos/o/r/issues/2', mode: { kind: 'status', status: 412, message: 'planted' } });
    const outcome = await cli(['issue-close', 'o/r', '1', '2', '--reason', 'not-planned'], environment);
    assert.equal(outcome.status, 4);
    assert.match(outcome.stderr, /Done before it failed: o\/r#1/);
  });

  it('prints neither the token nor what the token command said (planted: the server and the command both repeat it)', async () => {
    fake.fail({ path: '/repos/o/r/issues/1', mode: { kind: 'status', status: 422, message: `bad token ${FAKE_TOKEN}` } });
    const echoed = await cli(['issue-thread', 'o/r', '1'], environment);
    assert.equal(echoed.status, 3);
    assert.ok(!echoed.stderr.includes(FAKE_TOKEN) && !echoed.stdout.includes(FAKE_TOKEN));
    fake.fail({ path: '/repos/issues/search', mode: { kind: 'status', status: 422, message: `bad token ${FAKE_TOKEN}` } });
    const listed = await cli(['issue-list', 'o/r'], environment);
    assert.equal(listed.status, 3);
    assert.ok(!listed.stderr.includes(FAKE_TOKEN) && !listed.stdout.includes(FAKE_TOKEN));
    const failing = await cli(['issue-thread', 'o/r', '1'], { ...environment, FORGEJO_TOKEN_COMMAND: 'echo secret-from-command; echo secret-from-command >&2; exit 5' });
    assert.equal(failing.status, 2);
    assert.ok(!failing.stderr.includes('secret-from-command'));
    assert.match(failing.stderr, /exited with status 5/);
  });
});

function listIn(file: string, variable: string): string[] {
  const match = new RegExp(`^${variable}="([^"]*)"`, 'm').exec(readFileSync(file, 'utf8'));
  assert.ok(match?.[1], `${variable} not found in ${file}`);
  return match[1].trim().split(/\s+/).sort();
}

describe('the dispatch of bin/ai-core', () => {
  const dispatcher = join(HARNESS_ROOT, 'bin', 'ai-core');
  const names = (text: string): string[] => text.split('\n').filter((line) => line.startsWith('  ')).map((line) => line.trim()).sort();

  it('knows the commands that cli.mts knows, and the ones it refuses (drift guard)', async () => {
    const top = await cli(['help']);
    // doctor is called by the Bash doctor, never as `ai-core doctor`, whose Bash script stays the one that runs
    assert.deepEqual(listIn(dispatcher, 'FORGEJO_NODE_COMMANDS'), names(top.stdout).filter((name) => name !== 'doctor'));
    assert.deepEqual(listIn(dispatcher, 'FORGEJO_REFUSED_COMMANDS'), Object.keys(REFUSED_ON_FORGEJO).sort());
  });

  it('refuses every board command with exit 2 and one line, before any Bash script runs', async () => {
    for (const command of Object.keys(REFUSED_ON_FORGEJO)) {
      const outcome = await run('bash', [dispatcher, command], { TRACKER: 'forgejo' });
      assert.equal(outcome.status, 2, command);
      assert.equal(outcome.stderr.trim().split('\n').length, 1, command);
      assert.match(outcome.stderr, new RegExp(`^error: ${command} is not available with TRACKER=forgejo: `), command);
    }
  });

  it('runs the Node part for a Forgejo command and the Bash script on GitHub (innocent case)', async () => {
    const forgejo = await run('bash', [dispatcher, 'issue-new', '--help'], { TRACKER: 'forgejo' });
    assert.equal(forgejo.status, 0);
    assert.match(forgejo.stdout, /^usage: issue-new \[--repo OWNER\/REPO\]/);
    const github = await run('bash', [dispatcher, 'issue-new', '--help'], { TRACKER: 'github' });
    assert.equal(github.status, 0);
    assert.match(github.stdout, /Create an issue and put it on the board/);
  });

  it('reads TRACKER, FORGEJO_URL and the token command from the config.env of the project', async () => {
    const project = join(work, 'project');
    mkdirSync(join(project, '.ai-core'), { recursive: true });
    await run('git', ['init', '-q', project], {});
    writeFileSync(join(project, '.ai-core', 'config.env'), 'TRACKER=forgejo\nFORGEJO_URL=http://127.0.0.1:1\nFORGEJO_TOKEN_COMMAND="printf token"\n');
    const reached = await run('bash', [dispatcher, 'issue-thread', 'o/r', '1'], {}, project);
    assert.equal(reached.status, 3);
    assert.match(reached.stderr, /^error: read issue o\/r#1: /);
    const board = await run('bash', [dispatcher, 'board-list'], {}, project);
    assert.equal(board.status, 2);
    assert.match(board.stderr, /not available with TRACKER=forgejo/);
  });

  it('runs a Bash board script when the refusal is taken out (planted dispatcher)', async () => {
    const planted = join(work, 'planted');
    mkdirSync(join(planted, 'bin'), { recursive: true });
    mkdirSync(join(planted, 'lib'), { recursive: true });
    cpSync(join(HARNESS_ROOT, 'lib', 'common.sh'), join(planted, 'lib', 'common.sh'));
    cpSync(join(HARNESS_ROOT, 'lib', 'forgejo'), join(planted, 'lib', 'forgejo'), { recursive: true });
    writeFileSync(join(planted, 'VERSION'), '0.0.0\n');
    const script = join(planted, 'bin', 'board-list.sh');
    writeFileSync(script, `#!/usr/bin/env bash\ntouch "${join(planted, 'ran')}"\n`);
    chmodSync(script, 0o755);
    const text = readFileSync(dispatcher, 'utf8').replace(/^FORGEJO_REFUSED_COMMANDS=".*"$/m, 'FORGEJO_REFUSED_COMMANDS=" "');
    assert.notEqual(text, readFileSync(dispatcher, 'utf8'));
    writeFileSync(join(planted, 'bin', 'ai-core'), text);
    await run('bash', [join(planted, 'bin', 'ai-core'), 'board-list'], { TRACKER: 'forgejo' });
    assert.ok(existsSync(join(planted, 'ran')), 'the planted dispatcher did not run the Bash board script');
  });
});

describe('the settings of the lifecycle commands, from the config.env of the project to the Node part', () => {
  it('hands over CI_GATE and LIVE_TAGS, with public and an empty list where the project sets none', async () => {
    const shims = join(work, 'shims');
    mkdirSync(shims, { recursive: true });
    const seen = join(work, 'seen');
    writeFileSync(join(shims, 'node'), `#!/bin/sh\nprintf '%s|%s' "$CI_GATE" "$LIVE_TAGS" > '${seen}'\n`);
    chmodSync(join(shims, 'node'), 0o755);
    const path = `${shims}:${process.env.PATH ?? ''}`;
    const configured = join(work, 'lifecycle-configured');
    mkdirSync(join(configured, '.ai-core'), { recursive: true });
    await run('git', ['init', '-q', configured], {});
    writeFileSync(join(configured, '.ai-core', 'config.env'), 'TRACKER=forgejo\nFORGEJO_URL=http://127.0.0.1:1\nFORGEJO_TOKEN_COMMAND="printf token"\nCI_GATE=none\nLIVE_TAGS="prod=landed test=deploy/test/*"\n');
    await run('bash', [join(HARNESS_ROOT, 'bin', 'ai-core'), 'integrate-issue', '1'], { PATH: path }, configured);
    assert.equal(readFileSync(seen, 'utf8'), 'none|prod=landed test=deploy/test/*');
    const plain = join(work, 'lifecycle-plain');
    mkdirSync(join(plain, '.ai-core'), { recursive: true });
    await run('git', ['init', '-q', plain], {});
    writeFileSync(join(plain, '.ai-core', 'config.env'), 'TRACKER=forgejo\nFORGEJO_URL=http://127.0.0.1:1\nFORGEJO_TOKEN_COMMAND="printf token"\n');
    await run('bash', [join(HARNESS_ROOT, 'bin', 'ai-core'), 'issue-proof', '1'], { PATH: path }, plain);
    assert.equal(readFileSync(seen, 'utf8'), 'public|');
  });
});

describe('the README', () => {
  const readme = readFileSync(join(HARNESS_ROOT, 'README.md'), 'utf8');
  const row = (label: string): string[] => {
    const match = new RegExp(`^\\| ${label} \\| (.*) \\|$`, 'm').exec(readme);
    assert.ok(match?.[1], `the README has no row '${label}'`);
    return [...match[1].matchAll(/`([a-z-]+)`/g)].map((entry) => entry[1] ?? '').sort();
  };

  it('lists as supported the commands the tracker runs, and as refused the ones it refuses', async () => {
    const top = await cli(['help']);
    const known = top.stdout.split('\n').filter((line) => line.startsWith('  ')).map((line) => line.trim()).filter((name) => name !== 'doctor').sort();
    assert.deepEqual(row('Run in Node'), known);
    assert.deepEqual(row('Refused with exit 2 and one line'), Object.keys(REFUSED_ON_FORGEJO).sort());
  });

  it('says that status reports what the tracker records', () => {
    assert.match(readme, /reports what the tracker records, not an observed deployment/);
  });
});
