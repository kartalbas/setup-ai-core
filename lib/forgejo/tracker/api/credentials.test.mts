import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { CredentialsError } from './client.mts';
import { createTokenSource } from './credentials.mts';
import type { CommandOutcome } from './credentials.mts';

const SECRET = 'secret-token-value-0123';

describe('the token command', () => {
  it('yields the token a command prints (innocent case)', async () => {
    const source = createTokenSource(`printf '%s\\n' ${SECRET}`);
    assert.equal(await source.read(), SECRET);
  });

  it('runs the command once', async () => {
    let runs = 0;
    const source = createTokenSource('unused', () => {
      runs++;
      return Promise.resolve({ exitCode: 0, signal: null, stdout: `${SECRET}\n`, timedOut: false } satisfies CommandOutcome);
    });
    await source.read();
    await source.read();
    assert.equal(runs, 1);
  });

  it('names a failing command and prints none of what it said (planted: it prints the token, then fails)', async () => {
    const source = createTokenSource(`echo ${SECRET}; echo ${SECRET} >&2; exit 7`);
    await assert.rejects(source.read(), (error: unknown) => {
      assert.ok(error instanceof CredentialsError);
      assert.equal(error.kind, 'configuration');
      assert.match(error.message, /exited with status 7/);
      assert.ok(!error.message.includes(SECRET));
      return true;
    });
  });

  it('refuses an empty answer and an answer of several words, without printing either', async () => {
    await assert.rejects(createTokenSource('true').read(), /printed no token/);
    await assert.rejects(createTokenSource(`printf 'one two'`).read(), (error: unknown) => error instanceof CredentialsError && /more than one token/.test(error.message) && !error.message.includes('one two'));
  });

  it('reports a command that cannot be started without its text', async () => {
    const source = createTokenSource(`start-${SECRET}`, () => Promise.reject(new Error(`spawn start-${SECRET} ENOENT`)));
    await assert.rejects(source.read(), (error: unknown) => error instanceof CredentialsError && !error.message.includes(SECRET));
  });

  it('redacts the token from a text once it is known, and leaves other text alone', async () => {
    const source = createTokenSource(`printf '%s' ${SECRET}`);
    assert.equal(source.redact(`before ${SECRET}`), `before ${SECRET}`);
    await source.read();
    assert.equal(source.redact(`a ${SECRET} b ${SECRET}`), 'a [token] b [token]');
    assert.equal(source.redact('nothing to hide'), 'nothing to hide');
  });
});
