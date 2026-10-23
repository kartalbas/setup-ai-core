import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { after, describe, it } from 'node:test';

// The module boundaries of lib/forgejo/tracker, held by reading the imports of every production
// file: api/ and git/ import only node: modules and their own folder, domain/ imports api/ and
// itself, commands/ imports domain/, git/ and itself (api/ for types only), and cli.mts composes
// them. Nothing in production imports testing/, lib/github or a Bash file, or a bare specifier
// that is not node:, nor forms a cycle; only cli.mts prints and exits.

const ALLOWED: Readonly<Record<string, readonly string[]>> = {
  api: ['api'],
  git: ['git'],
  domain: ['api', 'domain'],
  commands: ['domain', 'git', 'commands'],
  '.': ['api', 'git', 'domain', 'commands', '.'],
};

interface Import {
  readonly specifier: string;
  readonly typeOnly: boolean;
}

function productionFiles(root: string): string[] {
  const found: string[] = [];
  const walk = (directory: string): void => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) {
        if (entry.name !== 'testing' && entry.name !== 'node_modules') walk(path);
      } else if (entry.name.endsWith('.mts') && !entry.name.endsWith('.test.mts')) {
        found.push(path);
      }
    }
  };
  walk(root);
  return found;
}

function importsOf(text: string): Import[] {
  const found: Import[] = [];
  for (const match of text.matchAll(/^\s*(import|export)\s+(type\s+)?[^;]*?\sfrom\s+'([^']+)'/gm)) {
    found.push({ specifier: match[3] ?? '', typeOnly: match[2] !== undefined });
  }
  for (const match of text.matchAll(/^\s*import\s+'([^']+)'/gm)) found.push({ specifier: match[1] ?? '', typeOnly: false });
  for (const match of text.matchAll(/\bimport\(\s*'([^']+)'\s*\)|\brequire\(\s*'([^']+)'\s*\)/g)) found.push({ specifier: match[1] ?? match[2] ?? '', typeOnly: false });
  return found;
}

function layerOf(root: string, file: string): string {
  const top = relative(root, file).split(sep)[0] ?? '';
  return top.endsWith('.mts') ? '.' : top;
}

export function analyze(root: string): string[] {
  const violations: string[] = [];
  const graph = new Map<string, string[]>();
  for (const file of productionFiles(root)) {
    const name = relative(root, file);
    const layer = layerOf(root, file);
    const text = readFileSync(file, 'utf8');
    if (ALLOWED[layer] === undefined) violations.push(`${name}: sits in no known layer`);
    if (name !== 'cli.mts' && /\bprocess\.exit\b|\bconsole\.|process\.std(out|err)/.test(text)) violations.push(`${name}: only cli.mts prints and exits`);
    if (/'PUT'/.test(text)) violations.push(`${name}: a PUT replaces the whole set of labels and is never sent`);
    const edges: string[] = [];
    for (const { specifier, typeOnly } of importsOf(text)) {
      if (specifier.startsWith('node:')) continue;
      if (!specifier.startsWith('.')) {
        violations.push(`${name}: imports the bare specifier '${specifier}'`);
        continue;
      }
      if (!specifier.endsWith('.mts')) {
        violations.push(`${name}: '${specifier}' does not name an .mts file`);
        continue;
      }
      const target = resolve(dirname(file), specifier);
      if (!target.startsWith(root + sep) || !existsSync(target)) {
        violations.push(`${name}: '${specifier}' leaves the tree or names no file`);
        continue;
      }
      const targetLayer = layerOf(root, target);
      if (targetLayer === 'testing') violations.push(`${name}: production imports testing/`);
      else if (layer !== targetLayer || layer === '.') {
        const allowed = ALLOWED[layer] ?? [];
        const typesOnly = layer === 'commands' && targetLayer === 'api' && typeOnly;
        if (!allowed.includes(targetLayer) && !typesOnly) violations.push(`${name}: ${layer === '.' ? 'the root' : layer + '/'} may not import ${targetLayer === '.' ? 'the root' : targetLayer + '/'} (${specifier})`);
      }
      edges.push(target);
    }
    graph.set(file, edges);
  }
  const state = new Map<string, 'visiting' | 'done'>();
  const visit = (file: string, path: string[]): void => {
    if (state.get(file) === 'done') return;
    if (state.get(file) === 'visiting') {
      violations.push(`cycle: ${[...path.slice(path.indexOf(file)), file].map((entry) => relative(root, entry)).join(' -> ')}`);
      return;
    }
    state.set(file, 'visiting');
    for (const next of graph.get(file) ?? []) visit(next, [...path, file]);
    state.set(file, 'done');
  };
  for (const file of graph.keys()) visit(file, []);
  return violations;
}

const roots: string[] = [];
function plant(files: Record<string, string>): string {
  const root = mkdtempSync(join(tmpdir(), 'forgejo-architecture-'));
  roots.push(root);
  for (const [name, content] of Object.entries(files)) {
    mkdirSync(dirname(join(root, name)), { recursive: true });
    writeFileSync(join(root, name), content);
  }
  return root;
}
after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

describe('the module boundaries of the tracker', () => {
  it('hold in the tree as it is', () => {
    assert.deepEqual(analyze(resolve(import.meta.dirname, '..')), []);
  });

  it('let commands reach domain and git, and domain reach api (innocent tree)', () => {
    const root = plant({
      'api/client.mts': "import { request } from 'node:http';\nexport const client = request;\n",
      'git/git.mts': "import { execFile } from 'node:child_process';\nexport const git = execFile;\n",
      'domain/issues.mts': "import { client } from '../api/client.mts';\nexport const issues = client;\n",
      'domain/labels.mts': "import { issues } from './issues.mts';\nexport const labels = issues;\n",
      'commands/status.mts': "import type { client } from '../api/client.mts';\nimport { labels } from '../domain/labels.mts';\nimport { git } from '../git/git.mts';\nexport const status = [labels, git];\nexport type Client = typeof client;\n",
      'cli.mts': "import { status } from './commands/status.mts';\nconsole.log(status);\n",
    });
    assert.deepEqual(analyze(root), []);
  });

  const planted: [string, Record<string, string>, RegExp][] = [
    ['domain imports commands', { 'commands/a.mts': 'export const a = 1;\n', 'domain/b.mts': "import { a } from '../commands/a.mts';\nexport const b = a;\n" }, /domain\/ may not import commands\//],
    ['api imports domain', { 'domain/a.mts': 'export const a = 1;\n', 'api/b.mts': "import { a } from '../domain/a.mts';\nexport const b = a;\n" }, /api\/ may not import domain\//],
    ['a cycle in domain', { 'domain/a.mts': "import { b } from './b.mts';\nexport const a = b;\n", 'domain/b.mts': "import { a } from './a.mts';\nexport const b = a;\n" }, /cycle: domain\/a.mts -> domain\/b.mts -> domain\/a.mts/],
    ['production imports testing', { 'testing/f.mts': 'export const f = 1;\n', 'domain/a.mts': "import { f } from '../testing/f.mts';\nexport const a = f;\n" }, /production imports testing\//],
    ['an import of lib/github', { 'domain/a.mts': "import { x } from '../../../github/tracker.sh';\nexport const a = x;\n" }, /does not name an \.mts file/],
    ['an import of a Bash file', { 'domain/a.mts': "import x from './tracker.sh';\nexport const a = x;\n" }, /does not name an \.mts file/],
    ['a bare specifier', { 'domain/a.mts': "import { z } from 'zod';\nexport const a = z;\n" }, /bare specifier 'zod'/],
    ['a command importing api for a value', { 'api/c.mts': 'export const c = 1;\n', 'commands/a.mts': "import { c } from '../api/c.mts';\nexport const a = c;\n" }, /commands\/ may not import api\//],
    ['an import without the extension', { 'domain/b.mts': 'export const b = 1;\n', 'domain/a.mts': "import { b } from './b';\nexport const a = b;\n" }, /does not name an \.mts file/],
    ['a command that prints', { 'commands/a.mts': "console.log('x');\n" }, /only cli\.mts prints and exits/],
    ['a PUT', { 'api/a.mts': "export const method = 'PUT';\n" }, /PUT replaces/],
  ];
  for (const [name, files, message] of planted) {
    it(`finds ${name} (planted defect)`, () => {
      assert.match(analyze(plant(files)).join('\n'), message);
    });
  }
});
