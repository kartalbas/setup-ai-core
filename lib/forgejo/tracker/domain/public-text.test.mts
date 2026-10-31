import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import { bashHarness } from '../harness.mts';
import { clientFor, startFakeForgejo } from '../testing/fake-forgejo.mts';
import type { FakeForgejo } from '../testing/fake-forgejo.mts';
import { createRecordingHarness } from '../testing/recording-harness.mts';
import { checkPublicText, findEmailAddress } from './public-text.mts';
import { PreconditionError } from './refusals.mts';

describe('the scan for email addresses', () => {
  const digest = 'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const refused: [string, string][] = [
    ['mail jane.doe@corp.com please', 'jane.doe@corp.com'],
    ['"quoted local"@evil.org', '"quoted local"@evil.org'],
    ['jane@exämple.de', 'jane@exämple.de'],
    ['x@[192.168.0.1]', 'x@[192.168.0.1]'],
    ['first@good.test then second@bad.org', 'second@bad.org'],
    ['ünï@cödé.com', 'ünï@cödé.com'],
    [`mongo:8.0.4@${digest} someone@company.ch`, 'someone@company.ch'],
    ['write to x@company。ch', 'x@company。ch'],
  ];
  for (const [text, address] of refused) {
    it(`finds ${address} (planted address)`, () => {
      assert.equal(findEmailAddress(text), address);
    });
  }
  // The ten code points besides letters, marks and numbers that IDNA2008 allows inside a label.
  for (const codePoint of [0x00b7, 0x0375, 0x05f3, 0x05f4, 0x06fd, 0x06fe, 0x0f0b, 0x200c, 0x200d, 0x30fb]) {
    const address = `info@a${String.fromCodePoint(codePoint)}b.ch`;
    it(`finds an address whose label holds U+${codePoint.toString(16).toUpperCase().padStart(4, '0')} (planted address)`, () => {
      assert.equal(findEmailAddress(`write to ${address} today`), address);
    });
  }

  const allowed = [
    'jane@example.com and x@y.test',
    'a.b@sub.example.net',
    '123+bob@users.noreply.github.com',
    'git clone git@host.example.org:owner/repo.git',
    'https://user:pw@host.example.org/x',
    'ssh://git@host.example.org:2222/o/r.git',
    'the package @scope/package-name and `@scope/pkg`',
    'user@localhost',
    'plain text with no address',
    `name:1.2.3@${digest}`,
    `mongo:8.0.4@${digest}`,
    `docker.io/library/mongo@${digest}`,
    'bob`@scope/pkg',
    '"bob"@scope/pkg',
    'tag v1@col\u00b7legi',
  ];
  for (const text of allowed) {
    it(`lets ${JSON.stringify(text)} pass (innocent text)`, () => {
      assert.equal(findEmailAddress(text), undefined);
    });
  }
});

// The recording harness judges no time; the Bash harness runs lib/stated-time.sh on the clock of AI_CORE_NOW.
const quiet = { cwd: process.cwd(), harness: createRecordingHarness() };
const judging = { cwd: process.cwd(), harness: bashHarness };

describe('the protection of a destination', () => {
  let fake: FakeForgejo;
  before(async () => {
    fake = await startFakeForgejo();
    fake.addRepository('o/open');
    fake.addRepository('o/closed', { isPrivate: true });
  });
  after(async () => {
    await fake.close();
  });

  it('refuses an address for a public repository and names the command', async () => {
    await assert.rejects(checkPublicText(quiet, clientFor(fake), 'issue-comment', { owner: 'o', repo: 'open' }, 'write to jane@corp.com'), (error: unknown) => error instanceof PreconditionError && /^issue-comment: refused email address jane@corp.com/.test(error.message));
  });

  it('lets an image digest reference into a public repository, and names the address beside it', async () => {
    const reference = 'mongo:8.0.4@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    await checkPublicText(quiet, clientFor(fake), 'issue-comment', { owner: 'o', repo: 'open' }, `pin ${reference}`);
    await assert.rejects(checkPublicText(quiet, clientFor(fake), 'issue-comment', { owner: 'o', repo: 'open' }, `pin ${reference} for someone@company.ch`), (error: unknown) => error instanceof PreconditionError && /refused email address someone@company\.ch /.test(error.message));
  });

  it('lets an address into a private repository (innocent case)', async () => {
    await checkPublicText(quiet, clientFor(fake), 'issue-comment', { owner: 'o', repo: 'closed' }, 'write to jane@corp.com');
  });

  it('scans where the visibility cannot be read', async () => {
    await assert.rejects(checkPublicText(quiet, clientFor(fake), 'issue-comment', { owner: 'o', repo: 'missing' }, 'write to jane@corp.com'), PreconditionError);
  });

  describe('the stated time', () => {
    const noon = String(Date.UTC(2026, 9, 31, 12, 0, 0) / 1000);
    let saved: Record<string, string | undefined>;
    before(() => {
      saved = { AI_CORE_NOW: process.env.AI_CORE_NOW, STATED_TIME_ZONE: process.env.STATED_TIME_ZONE };
      process.env.AI_CORE_NOW = noon;
      process.env.STATED_TIME_ZONE = 'UTC';
    });
    after(() => {
      for (const [key, value] of Object.entries(saved)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
    });

    it('refuses a time the clock does not show, in a private repository as in a public one, and names both', async () => {
      for (const repo of ['open', 'closed']) {
        await assert.rejects(checkPublicText(judging, clientFor(fake), 'issue-comment', { owner: 'o', repo }, 'landed at 13:10 UTC'), (error: unknown) => error instanceof PreconditionError && /^issue-comment to o\/\w+: the text says 13:10 UTC, the clock there shows 12:00/.test(error.message));
      }
    });

    it('lets the time of the clock, a time with its date and a time with no zone word pass (innocent cases)', async () => {
      for (const text of ['landed at 12:03 UTC', 'landed on 2026-10-30 at 09:10 UTC', 'the run took 13:10 in total']) {
        await checkPublicText(judging, clientFor(fake), 'issue-comment', { owner: 'o', repo: 'open' }, text);
      }
    });
  });
});
