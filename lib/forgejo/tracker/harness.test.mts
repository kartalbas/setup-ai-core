import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { after, describe, it } from 'node:test';
import { bashHarness } from './harness.mts';
import { createGitFixture, git } from './testing/git-fixture.mts';

// The harness steps run the Bash of the harness itself, here on disposable clones.
const fixture = createGitFixture();
after(() => fixture.dispose());

describe('the harness steps', () => {
  const remote = fixture.createRemote('o', 'shop');
  const checkout = fixture.clone(remote, 'project', 'shop');
  const other = fixture.clone(remote, 'other', 'shop');

  it('fast-forward the default branch of a clean checkout that is behind origin (innocent case)', async () => {
    const landed = fixture.commit(other, 'landed.txt', 'landed\n');
    git(other, 'push', '-q', 'origin', 'master');
    const outcome = await bashHarness.refreshCheckout(checkout);
    assert.equal(outcome.succeeded, true, outcome.output);
    assert.equal(git(checkout, 'rev-parse', 'master'), landed);
  });

  it('read the most rounds of a landing from the config.env as it stands at each call, 3 where it sets none, and name the key where the value is none (planted: a broken value)', async () => {
    const file = join(checkout, '.ai-core', 'config.env');
    mkdirSync(join(checkout, '.ai-core'), { recursive: true });
    const read = async (value?: string): Promise<{ succeeded: boolean; output: string }> => {
      writeFileSync(file, value === undefined ? 'UPDATE_CHECK="never"\n' : `INTEGRATE_MAX_ROUNDS=${value}\n`);
      return bashHarness.readLandingRounds(checkout);
    };
    assert.deepEqual(await read(), { succeeded: true, output: '3' });
    assert.deepEqual(await read('"5"'), { succeeded: true, output: '5' });
    assert.deepEqual(await read('1'), { succeeded: true, output: '1' });
    for (const broken of ['"soon"', '0', '-1', '1.5', '03', '99999999999']) {
      const outcome = await read(broken);
      assert.equal(outcome.succeeded, false, broken);
      assert.match(outcome.output, /^INTEGRATE_MAX_ROUNDS is '[^']*' in .*config\.env; it is the most rounds a landing makes, the first one counted, a whole number from 1 to 999999999$/, broken);
    }
    rmSync(file);
  });

  it('read the path of a receipt from standard output alone, so a warning on standard error refuses nothing (planted: a warning on standard error)', async () => {
    const warning = join(fixture.root, 'warn-on-stderr.sh');
    writeFileSync(warning, 'echo "bash: a warning of the shell" >&2\n');
    const saved = process.env.BASH_ENV;
    process.env.BASH_ENV = warning;
    try {
      const opened = await bashHarness.openLandingCheck(checkout);
      assert.equal(opened.succeeded, true, opened.output);
      assert.match(opened.output, /^\/[^\n]*\/receipt$/, 'the path alone, without the warning');
      assert.equal((await bashHarness.closeLandingCheck(opened.output)).succeeded, true);
    } finally {
      if (saved === undefined) delete process.env.BASH_ENV;
      else process.env.BASH_ENV = saved;
    }
  });

  it('open a receipt of the checks of a landing in a folder of its own, complete nothing where the gate wrote none, and close it (planted: a path that is no receipt)', async () => {
    const opened = await bashHarness.openLandingCheck(checkout);
    assert.equal(opened.succeeded, true, opened.output);
    assert.match(opened.output, /\/receipt$/);
    const other = await bashHarness.openLandingCheck(checkout);
    assert.notEqual(other.output, opened.output, 'two landings never share a receipt');
    assert.equal((await bashHarness.closeLandingCheck(other.output)).succeeded, true);
    const commit = git(checkout, 'rev-parse', 'HEAD');
    assert.equal((await bashHarness.completeLandingCheck(opened.output, commit, 'refs/heads/ci/integrate-x')).succeeded, true, 'no receipt written: nothing to complete');
    writeFileSync(opened.output, `landing-check\t1\ncommit\t${'0'.repeat(40)}\ncheck\tgreen\n`);
    const refused = await bashHarness.completeLandingCheck(opened.output, commit, 'refs/heads/ci/integrate-x');
    assert.equal(refused.succeeded, false);
    assert.match(refused.output, /holds no green check of /);
    assert.equal((await bashHarness.closeLandingCheck(opened.output)).succeeded, true);
    assert.equal(existsSync(opened.output), false);
    assert.equal(existsSync(join(opened.output, '..')), false, 'its folder goes too');
    assert.equal((await bashHarness.closeLandingCheck(join(checkout, 'README.md'))).succeeded, false, 'a file that is no receipt is never removed');
  });

  it('open the mark of a landing for a commit and its refs, read from standard output alone, and close it (planted: a path that is no mark)', async () => {
    const commit = git(checkout, 'rev-parse', 'HEAD');
    const opened = await bashHarness.openLandingMark(checkout, commit, ['refs/heads/master', 'refs/heads/ci/integrate-x']);
    assert.equal(opened.succeeded, true, opened.output);
    assert.match(opened.output, /^\/[^\n]*\/mark$/);
    const lines = readFileSync(opened.output, 'utf8').split('\n');
    assert.deepEqual(lines.filter((line) => line.startsWith('commit\t') || line.startsWith('ref\t')), [`commit\t${commit}`, 'ref\trefs/heads/master', 'ref\trefs/heads/ci/integrate-x']);
    assert.equal((await bashHarness.closeLandingMark(opened.output)).succeeded, true);
    assert.equal(existsSync(join(opened.output, '..')), false, 'its folder goes too');
    assert.equal((await bashHarness.closeLandingMark(join(checkout, 'README.md'))).succeeded, false, 'a file that is no mark is never removed');
  });

  it('leave a checkout with changes as it is and say why (planted: a dirty checkout)', async () => {
    fixture.commit(other, 'later.txt', 'later\n');
    git(other, 'push', '-q', 'origin', 'master');
    const before = git(checkout, 'rev-parse', 'master');
    writeFileSync(join(checkout, 'draft.txt'), 'somebody is writing\n');
    const outcome = await bashHarness.refreshCheckout(checkout);
    assert.equal(outcome.succeeded, false);
    assert.match(outcome.output, /not refreshed: .*uncommitted changes/);
    assert.equal(git(checkout, 'rev-parse', 'master'), before);
  });

  it('assemble nothing in a worktree of a harness source, which reads its own rules', async () => {
    const source = fixture.clone(fixture.createRemote('o', 'shop-ai-core'), 'project', 'shop-ai-core');
    git(source, 'remote', 'set-url', 'origin', 'https://github.com/o/shop-ai-core.git');
    const outcome = await bashHarness.assembleWorktree(source);
    assert.equal(outcome.succeeded, true, outcome.output);
    assert.match(outcome.output, /^Harness source worktree: run ai-core session-start/);
  });

  it('read LIVE_TAGS through the Bash configuration reader, ignoring the environment', async () => {
    mkdirSync(join(checkout, '.ai-core'), { recursive: true });
    writeFileSync(join(checkout, '.ai-core', 'config.env'), 'LIVE_TAGS="test=landed"\n  LIVE_TAGS = \'prod=landed test=deploy/test/*\' # the last declaration wins\n');
    const previous = process.env.LIVE_TAGS;
    process.env.LIVE_TAGS = 'prod=deploy/prod/*';
    try {
      const outcome = await bashHarness.readLiveTags(checkout);
      assert.deepEqual(outcome, { succeeded: true, output: 'prod=landed test=deploy/test/*' });
    } finally {
      if (previous === undefined) delete process.env.LIVE_TAGS;
      else process.env.LIVE_TAGS = previous;
    }
  });

  it('refuse to read LIVE_TAGS from a checkout that is missing (planted)', async () => {
    const outcome = await bashHarness.readLiveTags(join(fixture.root, 'missing'));
    assert.equal(outcome.succeeded, false);
    assert.notEqual(outcome.output, '');
  });
});
