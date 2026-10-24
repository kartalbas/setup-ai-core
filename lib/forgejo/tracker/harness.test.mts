import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
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
