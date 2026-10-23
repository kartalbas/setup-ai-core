import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { after, describe, it } from 'node:test';

// The type check is red for a planted type error and green for a correct fixture. The compiler is
// the development-only one under tests/typescript; without it this file fails, and never skips.

const tracker = resolve(import.meta.dirname, '..');
const typescript = resolve(tracker, '../../../tests/typescript');
const compiler = join(typescript, 'node_modules', '.bin', 'tsc');
const shapes = join(tracker, 'api', 'shapes.mts');
const directories: string[] = [];

function check(source: string): { status: number | null; output: string } {
  assert.ok(existsSync(compiler), `the compiler is missing: run npm ci --prefix tests/typescript (${compiler})`);
  const directory = mkdtempSync(join(tmpdir(), 'forgejo-typecheck-'));
  directories.push(directory);
  const options = (JSON.parse(readFileSync(join(tracker, 'tsconfig.json'), 'utf8')) as { compilerOptions: Record<string, unknown> }).compilerOptions;
  writeFileSync(join(directory, 'tsconfig.json'), JSON.stringify({ compilerOptions: { ...options, typeRoots: [join(typescript, 'node_modules', '@types')] }, include: ['fixture.mts'] }));
  writeFileSync(join(directory, 'fixture.mts'), source.replaceAll('SHAPES', shapes));
  const result = spawnSync(compiler, ['-p', directory], { encoding: 'utf8' });
  return { status: result.status, output: `${result.stdout}${result.stderr}` };
}
after(() => {
  for (const directory of directories) rmSync(directory, { recursive: true, force: true });
});

describe('the type check', () => {
  it('passes a correct request and a validated response (innocent fixture)', () => {
    const result = check(`
      import { issueShape } from 'SHAPES';
      import type { CreateIssueBody } from 'SHAPES';
      export const request: CreateIssueBody = { title: 'A title', labels: [1, 2] };
      export const issue = issueShape.type.read({}, 'where');
      export const name: string = issue.repository === undefined ? '' : issue.repository.full_name;
    `);
    assert.equal(result.status, 0, result.output);
  });

  it('is red for a request field of the wrong type (planted)', () => {
    const result = check(`
      import type { CreateIssueBody } from 'SHAPES';
      export const request: CreateIssueBody = { title: 5 };
    `);
    assert.notEqual(result.status, 0);
    assert.match(result.output, /TS2322/);
  });

  it('is red for an optional field read without a check (planted)', () => {
    const result = check(`
      import { issueShape } from 'SHAPES';
      export const issue = issueShape.type.read({}, 'where');
      export const name: string = issue.repository.full_name;
    `);
    assert.notEqual(result.status, 0);
    assert.match(result.output, /TS18048|TS2532/);
  });

  it('is red for what Node cannot strip: an enum (planted)', () => {
    const result = check('export enum Kind { A }\n');
    assert.notEqual(result.status, 0);
    assert.match(result.output, /TS1294/);
  });

  it('is red for a relative import without the .mts extension (planted)', () => {
    const result = check(`import { issueShape } from '${shapes.replace(/\.mts$/, '')}';\nexport const x = issueShape;\n`);
    assert.notEqual(result.status, 0);
  });
});
