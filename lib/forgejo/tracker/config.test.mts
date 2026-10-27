import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { appendFileSync, cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, describe, it } from 'node:test';
import { ConfigError, parseForgejoUrl, readSettings, requireConfig } from './config.mts';

const HARNESS_ROOT = new URL('../../../', import.meta.url).pathname.replace(/\/$/, '');

describe('the settings of the environment', () => {
  it('treat an empty value as not set', () => {
    const settings = readSettings({ TRACKER: 'forgejo', FORGEJO_URL: '  ', FORGEJO_TOKEN_COMMAND: '', AI_CORE_LABELS_FILE: undefined });
    assert.equal(settings.tracker, 'forgejo');
    assert.equal(settings.forgejoUrl, undefined);
    assert.equal(settings.tokenCommand, undefined);
    assert.equal(settings.labelsFile, undefined);
  });
});

describe('the settings of the lifecycle commands', () => {
  it('are read from the environment, and an empty value is not set', () => {
    const settings = readSettings({ CI_GATE: 'none', LIVE_TAGS: 'prod=landed', AI_CORE_INTEGRATE_POLL: '5', AI_CORE_INTEGRATE_WAIT: ' ' });
    assert.equal(settings.ciGate, 'none');
    assert.equal(settings.liveTags, 'prod=landed');
    assert.equal(settings.integratePollSeconds, '5');
    assert.equal(settings.integrateWaitSeconds, undefined);
  });
});

describe('FORGEJO_URL', () => {
  it('is a scheme and a host, as typed or with a closing slash (innocent cases)', () => {
    assert.equal(parseForgejoUrl('https://forge.example.test'), 'https://forge.example.test');
    assert.equal(parseForgejoUrl('https://forge.example.test/'), 'https://forge.example.test');
    assert.equal(parseForgejoUrl('http://127.0.0.1:3000'), 'http://127.0.0.1:3000');
  });

  const malformed: [string, RegExp][] = [
    ['forge.example.test', /not an address/],
    ['ftp://forge.example.test', /https:\/\/ or http:\/\//],
    ['https://user:secret@forge.example.test', /credentials/],
    ['https://forge.example.test/api/v1', /nothing after it/],
    ['https://forge.example.test/?x=1', /nothing after it/],
    ['', /not an address/],
  ];
  for (const [text, message] of malformed) {
    it(`refuses ${JSON.stringify(text)}`, () => {
      assert.throws(() => parseForgejoUrl(text), (error: unknown) => error instanceof ConfigError && message.test(error.message) && !error.message.includes('secret'));
    });
  }
});

describe('the configuration a command needs', () => {
  const complete = readSettings({ TRACKER: 'Forgejo', FORGEJO_URL: 'https://forge.example.test', FORGEJO_TOKEN_COMMAND: 'printf token' });

  it('is complete, with TRACKER read without regard to case (innocent case)', () => {
    assert.deepEqual(requireConfig(complete), { forgejoUrl: 'https://forge.example.test', tokenCommand: 'printf token' });
  });

  it('names what is missing', () => {
    assert.throws(() => requireConfig({ ...complete, forgejoUrl: undefined }), /FORGEJO_URL is not set/);
    assert.throws(() => requireConfig({ ...complete, tokenCommand: undefined }), /FORGEJO_TOKEN_COMMAND is not set/);
  });

  it('refuses another tracker and an unset one', () => {
    assert.throws(() => requireConfig({ ...complete, tracker: 'github' }), /TRACKER is 'github'/);
    assert.throws(() => requireConfig({ ...complete, tracker: undefined }), /TRACKER is 'not set'/);
  });
});

function git(cwd: string, ...args: string[]): string {
  return execFileSync('git', ['-C', cwd, ...args], { encoding: 'utf8', env: { ...process.env, GIT_AUTHOR_NAME: 'Example', GIT_AUTHOR_EMAIL: 'example@example.test', GIT_COMMITTER_NAME: 'Example', GIT_COMMITTER_EMAIL: 'example@example.test' } }).trim();
}

function bashIn(cwd: string, root: string, script: string, extraEnvironment: Record<string, string> = {}): { status: number | null; stdout: string; stderr: string } {
  const environment: Record<string, string | undefined> = { ...process.env };
  for (const name of ['TRACKER', 'FORGE', 'FORGEJO_URL', 'FORGEJO_TOKEN_COMMAND']) delete environment[name];
  Object.assign(environment, extraEnvironment);
  const result = spawnSync('bash', ['-c', script, '_', root], { cwd, env: environment, encoding: 'utf8', timeout: 30_000 });
  return { status: result.status, stdout: result.stdout.trim(), stderr: result.stderr.trim() };
}

describe('the settings of the Bash part, read from the main checkout', () => {
  let work: string;
  let main: string;
  let tree: string;
  before(() => {
    work = mkdtempSync(join(tmpdir(), 'forgejo-config-'));
    main = join(work, 'shop-web');
    mkdirSync(join(main, '.ai-core'), { recursive: true });
    git(main, 'init', '-q', '--initial-branch=master');
    git(main, 'remote', 'add', 'origin', 'https://forge.example.test/example-org/shop-web.git');
    writeFileSync(join(main, '.ai-core', 'config.env'), 'TRACKER=forgejo\nFORGE=forgejo\nFORGEJO_URL=https://forge.example.test\nFORGEJO_TOKEN_COMMAND="cat /example/token"\nOTHER_SETTING=main\n');
    git(main, 'commit', '-q', '--allow-empty', '-m', 'start');
    tree = join(work, 'tree');
    git(main, 'worktree', 'add', '-q', tree, '-b', 'issue-1-tree');
    mkdirSync(join(tree, '.ai-core'), { recursive: true });
    writeFileSync(join(tree, '.ai-core', 'config.env'), 'TRACKER=github\nFORGE=github\nFORGEJO_URL=https://stale.example.test\nFORGEJO_TOKEN_COMMAND="cat /stale/token"\nOTHER_SETTING=worktree\n');
  });
  after(() => rmSync(work, { recursive: true, force: true }));

  const read = (key: string): string => bashIn(tree, HARNESS_ROOT, `. "$1/lib/common.sh"; config_value ${key} none`).stdout;

  it('reads FORGE, FORGEJO_URL and FORGEJO_TOKEN_COMMAND from the main checkout, not from the worktree', () => {
    assert.equal(read('TRACKER'), 'forgejo');
    assert.equal(read('FORGE'), 'forgejo');
    assert.equal(read('FORGEJO_URL'), 'https://forge.example.test');
    assert.equal(read('FORGEJO_TOKEN_COMMAND'), 'cat /example/token');
  });

  it('leaves a setting beyond them the worktree\'s own (innocent case)', () => {
    assert.equal(read('OTHER_SETTING'), 'worktree');
  });

  it('hands the tracker the assignee map and the label catalog of the worktree it runs in', () => {
    const shim = join(work, 'shim');
    mkdirSync(shim, { recursive: true });
    writeFileSync(join(shim, 'node'), '#!/bin/sh\nprintf "%s\\n%s\\n" "$AI_CORE_ASSIGNEES_FILE" "$AI_CORE_LABELS_FILE"\n', { mode: 0o755 });
    writeFileSync(join(tree, '.ai-core', 'assignees.tsv'), 'example-org/shop-web\tfirst\n');
    const result = bashIn(tree, HARNESS_ROOT, '. "$1/lib/common.sh"; forgejo_tracker_exec issue-new', { PATH: `${shim}:${process.env.PATH ?? ''}` });
    assert.equal(result.status, 0, result.stderr);
    const [assignees, labels] = result.stdout.split('\n');
    assert.equal(assignees, join(tree, '.ai-core', 'assignees.tsv'));
    assert.equal(labels, join(HARNESS_ROOT, 'templates', '.ai-core', 'labels.tsv'), 'planted: a worktree without labels.tsv falls back to the template, as the assignee map does');
  });

  it('lets the environment win', () => {
    assert.equal(bashIn(tree, HARNESS_ROOT, '. "$1/lib/common.sh"; config_value FORGEJO_URL none', { FORGEJO_URL: 'https://env.example.test' }).stdout, 'https://env.example.test');
  });
});

describe('a harness clone reads FORGE without loading a provider', () => {
  let work: string;
  let layer: string;
  let product: string;
  let plantedRoot: string;
  let trace: string;
  before(() => {
    work = mkdtempSync(join(tmpdir(), 'forgejo-recursion-'));
    layer = join(work, 'shop-ai-core');
    mkdirSync(layer);
    git(layer, 'init', '-q', '--initial-branch=master');
    git(layer, 'remote', 'add', 'origin', 'https://forge.example.test/example-org/shop-ai-core.git');
    writeFileSync(join(layer, 'config.env'), 'FORGE=forgejo\nFORGEJO_URL=https://forge.example.test\n');
    product = join(work, 'shop-web');
    mkdirSync(product);
    git(product, 'init', '-q', '--initial-branch=master');
    git(product, 'remote', 'add', 'origin', 'https://forge.example.test/example-org/shop-web.git');
    writeFileSync(join(product, 'config.env'), 'FORGE=forgejo\n');
    plantedRoot = join(work, 'planted');
    mkdirSync(plantedRoot);
    cpSync(join(HARNESS_ROOT, 'lib'), join(plantedRoot, 'lib'), { recursive: true });
    trace = join(work, 'trace');
    writeFileSync(trace, '');
    appendFileSync(
      join(plantedRoot, 'lib', 'common.sh'),
      `\nis_harness_clone() {\n  echo x >> "${trace}"\n  [ "$(wc -l < "${trace}")" -le 6 ] || return 1\n  ( . "$HARNESS_ROOT/lib/layers.sh" && harness_source_of "$1" ) >/dev/null 2>&1\n}\n`,
    );
  });
  after(() => rmSync(work, { recursive: true, force: true }));

  const loadForge = '. "$1/lib/forge.sh"; echo "$FORGE $(type -t forge_host)"';

  it('loads the forge provider named by the layer\'s config.env and ends', () => {
    const result = bashIn(layer, HARNESS_ROOT, loadForge);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'forgejo function');
  });

  it('asks whether a checkout is a harness clone without loading any provider', () => {
    const result = bashIn(layer, HARNESS_ROOT, '. "$1/lib/common.sh"; is_harness_clone "$PWD" && echo yes; echo "[$(type -t forge_host)]"');
    assert.equal(result.stdout, 'yes\n[]');
  });

  it('does not read the config.env at the root of a product clone (innocent case)', () => {
    assert.equal(bashIn(product, HARNESS_ROOT, '. "$1/lib/common.sh"; config_value FORGE none').stdout, 'none');
  });

  it('would recurse if the choice of the file loaded a provider (planted recursion)', () => {
    bashIn(layer, plantedRoot, loadForge);
    const calls = readFileSync(trace, 'utf8').split('\n').filter((line) => line !== '').length;
    assert.ok(calls > 1, `the planted copy asked ${calls} time(s) and did not recurse`);
  });
});

describe('FORGEJO_URL in the Bash provider, which the credential helper and init read, agrees with the tracker', () => {
  const accepted = ['https://forge.example.test', 'https://forge.example.test/', 'http://127.0.0.1:3000'];
  const refused = [
    'https://user:secret@forge.example.test',
    'https://forge.example.test/api/v1',
    'https://forge.example.test/?x=1',
    'https://forge.example.test?x=1',
    'https://forge.example.test#top',
    'ftp://forge.example.test',
  ];
  const ask = (root: string, url: string) => bashIn(root, root, '. "$1/lib/forgejo/forge.sh"; forgejo_url_of "$URL_UNDER_TEST"', { URL_UNDER_TEST: url });

  for (const url of accepted) {
    it(`takes ${JSON.stringify(url)} as the tracker does (innocent case)`, () => {
      const result = ask(HARNESS_ROOT, url);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout, parseForgejoUrl(url));
    });
  }
  for (const url of refused) {
    it(`refuses ${JSON.stringify(url)} as the tracker does, without repeating a password`, () => {
      assert.throws(() => parseForgejoUrl(url), ConfigError);
      const result = ask(HARNESS_ROOT, url);
      assert.notEqual(result.status, 0, `the Bash provider took ${url}`);
      assert.ok(!`${result.stdout}${result.stderr}`.includes('secret'), result.stderr);
    });
  }

  it('would take credentials if the check were taken out (planted)', () => {
    const work = mkdtempSync(join(tmpdir(), 'forgejo-url-'));
    try {
      mkdirSync(join(work, 'lib', 'forgejo'), { recursive: true });
      cpSync(join(HARNESS_ROOT, 'lib', 'common.sh'), join(work, 'lib', 'common.sh'));
      const text = readFileSync(join(HARNESS_ROOT, 'lib', 'forgejo', 'forge.sh'), 'utf8');
      const planted = text.replace('*@*) die "FORGEJO_URL must not carry credentials" ;;', '*@*) ;;');
      assert.notEqual(planted, text, 'the check to take out was not found');
      writeFileSync(join(work, 'lib', 'forgejo', 'forge.sh'), planted);
      assert.equal(ask(work, 'https://user:secret@forge.example.test').status, 0);
    } finally {
      rmSync(work, { recursive: true, force: true });
    }
  });
});
