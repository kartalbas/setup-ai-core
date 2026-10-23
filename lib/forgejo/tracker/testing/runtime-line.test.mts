import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, it } from 'node:test';

// The runtime of the Forgejo tracker is one Node line, and the type declarations the type check holds the code
// against must be that line's, so that the check accepts no API the runtime lacks. CI names the line, the
// package.json under tests/typescript pins the declarations, and CI installs the compiler before the suite runs.

const ROOT = resolve(import.meta.dirname, '../../../..');

export function analyze(workflow: string, packageJson: string): string[] {
  const problems: string[] = [];
  const line = /^\s+node-version:\s*(\d+)\s*$/m.exec(workflow)?.[1];
  if (!/uses:\s*actions\/setup-node@v\d+\s*$/m.test(workflow)) problems.push('the workflow does not set up Node with actions/setup-node');
  if (line === undefined) problems.push('the workflow names no whole Node major as node-version');
  const install = workflow.indexOf('npm ci --prefix tests/typescript');
  const suite = workflow.indexOf('bash tests/check.sh');
  if (install < 0) problems.push('the workflow does not install the compiler with npm ci --prefix tests/typescript');
  else if (suite >= 0 && install > suite) problems.push('the workflow installs the compiler after it runs the suite');
  const declared = (JSON.parse(packageJson) as { devDependencies?: Record<string, string> }).devDependencies?.['@types/node'];
  if (declared === undefined || !/^\d+\.\d+\.\d+$/.test(declared)) problems.push(`@types/node is '${declared ?? 'not there'}', and it must be one exact version`);
  else if (line !== undefined && declared.split('.')[0] !== line) problems.push(`@types/node ${declared} is not of the Node line ${line} that CI runs`);
  return problems;
}

const workflow = `steps:
  - uses: actions/checkout@v5
  - uses: actions/setup-node@v7
    with:
      node-version: 24
  - run: npm ci --prefix tests/typescript
  - run: bash tests/check.sh
`;
const pinned = '{"devDependencies":{"@types/node":"24.19.2","typescript":"7.0.2"}}';

describe('the Node line of the Forgejo tracker', () => {
  it('is one for the runtime in CI and the declarations of the type check, in the repository as it is', () => {
    const problems = analyze(readFileSync(resolve(ROOT, '.github/workflows/check.yml'), 'utf8'), readFileSync(resolve(ROOT, 'tests/typescript/package.json'), 'utf8'));
    assert.deepEqual(problems, []);
  });

  it('accepts a workflow and a pin of the same line (innocent case)', () => {
    assert.deepEqual(analyze(workflow, pinned), []);
  });

  const planted: [string, string, string, RegExp][] = [
    ['declarations of another Node line', workflow, '{"devDependencies":{"@types/node":"26.6.5"}}', /not of the Node line 24/],
    ['a range instead of one version', workflow, '{"devDependencies":{"@types/node":"^24.19.2"}}', /one exact version/],
    ['no Node set up', workflow.replace('actions/setup-node@v7', 'actions/cache@v4'), pinned, /does not set up Node/],
    ['no compiler installed', workflow.replace('npm ci --prefix tests/typescript', 'true'), pinned, /does not install the compiler/],
    ['the compiler installed after the suite', workflow.replace('  - run: npm ci --prefix tests/typescript\n  - run: bash tests/check.sh\n', '  - run: bash tests/check.sh\n  - run: npm ci --prefix tests/typescript\n'), pinned, /after it runs the suite/],
  ];
  for (const [name, text, json, message] of planted) {
    it(`finds ${name} (planted defect)`, () => {
      assert.match(analyze(text, json).join('\n'), message);
    });
  }
});
