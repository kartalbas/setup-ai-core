import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import { clientFor, startFakeForgejo } from '../testing/fake-forgejo.mts';
import type { FakeForgejo } from '../testing/fake-forgejo.mts';
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
    await assert.rejects(checkPublicText(clientFor(fake), 'issue-comment', { owner: 'o', repo: 'open' }, 'write to jane@corp.com'), (error: unknown) => error instanceof PreconditionError && /^issue-comment: refused email address jane@corp.com/.test(error.message));
  });

  it('lets an image digest reference into a public repository, and names the address beside it', async () => {
    const reference = 'mongo:8.0.4@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    await checkPublicText(clientFor(fake), 'issue-comment', { owner: 'o', repo: 'open' }, `pin ${reference}`);
    await assert.rejects(checkPublicText(clientFor(fake), 'issue-comment', { owner: 'o', repo: 'open' }, `pin ${reference} for someone@company.ch`), (error: unknown) => error instanceof PreconditionError && /refused email address someone@company\.ch /.test(error.message));
  });

  it('lets an address into a private repository (innocent case)', async () => {
    await checkPublicText(clientFor(fake), 'issue-comment', { owner: 'o', repo: 'closed' }, 'write to jane@corp.com');
  });

  it('scans where the visibility cannot be read', async () => {
    await assert.rejects(checkPublicText(clientFor(fake), 'issue-comment', { owner: 'o', repo: 'missing' }, 'write to jane@corp.com'), PreconditionError);
  });
});
