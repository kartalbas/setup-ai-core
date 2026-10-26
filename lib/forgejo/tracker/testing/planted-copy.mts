import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

// A copy of the tracker with a defect planted in it, so that a test can show its check goes red on the defect and stays
// green on the real code. Each replacement names a file of the tracker, the text there and the text that takes its place;
// a text that is not found fails the test, because a plant that did not take proves nothing.
export type Planted = readonly [file: string, from: string, to: string];

export function plantedCopy(replacements: readonly Planted[]): string {
  const copy = mkdtempSync(join(tmpdir(), 'forgejo-planted-'));
  cpSync(resolve(import.meta.dirname, '..'), copy, { recursive: true });
  for (const [file, from, to] of replacements) {
    const path = join(copy, file);
    const text = readFileSync(path, 'utf8');
    assert.ok(text.includes(from), `the plant did not take in ${file}`);
    writeFileSync(path, text.replace(from, to));
  }
  return copy;
}
