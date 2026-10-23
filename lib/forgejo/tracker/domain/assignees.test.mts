import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, describe, it } from 'node:test';
import { findOwnerLogin, parseAssigneeMap } from './assignees.mts';
import { UsageError } from './refusals.mts';

const directory = mkdtempSync(join(tmpdir(), 'forgejo-assignees-'));
after(() => rmSync(directory, { recursive: true, force: true }));

describe('the assignee map', () => {
  it('reads one login per repository, and skips comments and blank lines (innocent case)', () => {
    const map = parseAssigneeMap('# who owns what\n\no/r\tfirst\no/s\tsecond\n', 'assignees.tsv');
    assert.deepEqual([...map], [['o/r', 'first'], ['o/s', 'second']]);
  });

  const refused: [string, string, RegExp][] = [
    ['a row with no tab', 'o/r first\n', /assignees\.tsv:1 is not 'repo<TAB>login': o\/r first/],
    ['a row with two tabs', '# c\no/r\tfirst\tmore\n', /assignees\.tsv:2 is not 'repo<TAB>login'/],
    ['a row with an empty login', 'o/r\t\n', /assignees\.tsv:1 is not 'repo<TAB>login'/],
    ['a space at the end of a login', 'o/r\tfirst \n', /assignees\.tsv:1 has a space at the edge of a column/],
    ['a space at the start of a repository', ' o/r\tfirst\n', /assignees\.tsv:1 has a space at the edge of a column/],
    ['an indented comment', ' # c\n', /assignees\.tsv:1 is not 'repo<TAB>login'/],
    ['a repository listed twice', 'o/r\tfirst\no/r\tsecond\n', /assignees\.tsv lists o\/r twice/],
  ];
  for (const [name, text, message] of refused) {
    it(`refuses ${name}, and names the row`, () => {
      assert.throws(() => parseAssigneeMap(text, 'assignees.tsv'), (error: unknown) => error instanceof UsageError && message.test(error.message));
    });
  }

  it('finds the login of a repository, nothing for one the file does not name, and refuses a missing file', async () => {
    const path = join(directory, 'assignees.tsv');
    writeFileSync(path, 'o/r\tfirst\n');
    assert.equal(await findOwnerLogin(path, { owner: 'o', repo: 'r' }), 'first');
    assert.equal(await findOwnerLogin(path, { owner: 'o', repo: 'other' }), undefined);
    await assert.rejects(findOwnerLogin(join(directory, 'missing.tsv'), { owner: 'o', repo: 'r' }), /cannot read the assignee map/);
    await assert.rejects(findOwnerLogin(undefined, { owner: 'o', repo: 'r' }), UsageError);
  });
});
