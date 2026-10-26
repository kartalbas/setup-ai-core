import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, describe, it } from 'node:test';
import { UsageError } from '../domain/refusals.mts';
import { bashHarness } from '../harness.mts';
import { contextFor, seedLabels, startFakeForgejo } from '../testing/fake-forgejo.mts';
import type { FakeForgejo } from '../testing/fake-forgejo.mts';
import { createRecordingHarness } from '../testing/recording-harness.mts';
import * as status from './status.mts';

const NOW = Date.UTC(2026, 0, 1, 12, 0, 0) / 1000;
const TOOL_VARIABLES = ['CODEX_SANDBOX', 'CODEX_SANDBOX_NETWORK_DISABLED', 'CODEX_THREAD_ID', 'ANTIGRAVITY_AGENT', 'CLAUDECODE', 'GEMINI_CLI', 'CODEX_HOME'];

describe('status --tokens', () => {
  let fake: FakeForgejo;
  let root: string;
  const saved = new Map<string, string | undefined>();
  const handed: { items: string; columns: string; board: string }[] = [];

  before(async () => {
    fake = await startFakeForgejo();
    fake.addRepository('o/one');
    seedLabels(fake, 'o');
    fake.addIssue('o/one', { title: 'Open work, so that it is counted open', labels: ['status/implementing', 'priority/p1'] });
    fake.addIssue('o/one', { title: 'Closed today, so that it is the pace', state: 'closed', closedAt: '2026-01-01T06:00:00Z', labels: ['status/done'] });
    fake.addIssue('o/one', { title: 'Closed long ago, so that it is no pace', state: 'closed', closedAt: '2025-12-01T06:00:00Z', labels: ['status/done'] });

    root = await mkdtemp(join(tmpdir(), 'status-tokens-'));
    const home = join(root, 'home');
    const project = join(root, 'project');
    const transcripts = join(root, 'transcripts');
    await mkdir(join(home, '.ai-core'), { recursive: true });
    await mkdir(project, { recursive: true });
    await mkdir(join(transcripts, project.replace(/[^A-Za-z0-9]/g, '-')), { recursive: true });
    await writeFile(join(home, '.ai-core', 'usage.json'), JSON.stringify({ recorded_at: NOW, rate_limits: { five_hour: { used_percentage: 25, resets_at: NOW + 3600 } } }));
    await writeFile(
      join(transcripts, project.replace(/[^A-Za-z0-9]/g, '-'), 'session.jsonl'),
      `${JSON.stringify({ type: 'assistant', timestamp: '2026-01-01T11:00:00.000Z', cwd: project, message: { id: 'm1', usage: { input_tokens: 1000, output_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 } } })}\n`,
    );
    const environment: Record<string, string | undefined> = {
      HOME: home, AI_CORE_HOME: home, AI_CORE_TRANSCRIPTS: transcripts, AI_CORE_NOW: String(NOW), TZ: 'UTC',
      ...Object.fromEntries(TOOL_VARIABLES.map((name) => [name, undefined])),
    };
    for (const [name, value] of Object.entries(environment)) {
      saved.set(name, process.env[name]);
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
  });
  after(async () => {
    for (const [name, value] of saved) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
    await fake.close();
    await rm(root, { recursive: true, force: true });
  });

  const contextAt = (harness = bashHarness) =>
    contextFor(fake, {
      cwd: join(root, 'project'),
      harness: {
        ...harness,
        readTokensPage: async (cwd, items, columns, board) => {
          handed.push({ items: await readFile(items, 'utf8'), columns: await readFile(columns, 'utf8'), board });
          return harness.readTokensPage(cwd, items, columns, board);
        },
      },
    });

  it('prints the usage windows, the pace, what an issue costs and the tokens, as the page of a board does', async () => {
    const result = await status.run(['o/one', '--tokens'], contextAt());
    const page = result.stdout.split('\n');
    assert.equal(result.exitCode, 0);
    assert.equal(page[0], 'project · board o/forgejo · Thu 01.01. 12:00');
    assert.equal(page[1], 'usage   5h 25 % (reset Thu 01.01. 13:00) · limit 92 %');
    assert.equal(page[2], 'pace    1 issues closed on the board in the last 24 hours, 0.1 a day over 14 days');
    assert.match(page[3] ?? '', /^cost    /);
    assert.equal(page[4], 'tokens  in 24 hours the sessions of this folder used 1k fresh and read 0 from the cache: 1k fresh and 0 from the cache per closed issue');
    assert.equal(page[6], 'open    1 issues · 0 epics, 0 ready to close · 1 outside epics');
    assert.equal(page.filter((line) => line.startsWith('reviews')).length, 0, 'Forgejo status holds no tally of reviews');
  });

  it('hands over every issue of the repositories, open and closed, as cards whose column is the status/ label', async () => {
    handed.length = 0;
    await status.run(['o/one', '--tokens'], contextAt());
    const cards = (handed[0]?.items ?? '').trim().split('\n').map((line) => JSON.parse(line) as { open: boolean; status: string; priority: string | null; closedAt: string | null; subs: number; parent: string | null });
    assert.deepEqual(cards.map((card) => `${card.open ? 'open' : 'closed'} ${card.status} ${card.priority ?? '-'}`), ['open implementing P1', 'closed done -', 'closed done -']);
    assert.ok(cards.every((card) => card.subs === 0 && card.parent === null), 'every card is a leaf, so the page can name no epic as ready to close');
    assert.equal(handed[0]?.columns.trim().split('\n').at(-1), 'not-planned');
    assert.equal(handed[0]?.board, 'o/forgejo');
  });

  it('refuses --state, --label and --json beside it, and names a page that could not be made', async () => {
    for (const refused of [['--state', 'closed'], ['--label', 'status/ready'], ['--json']]) {
      await assert.rejects(status.run(['o/one', '--tokens', ...refused], contextAt()), UsageError);
    }
    const harness = createRecordingHarness();
    harness.failing.add('readTokensPage');
    await assert.rejects(status.run(['o/one', '--tokens'], contextFor(fake, { harness })), /the page of status --tokens could not be made: planted: readTokensPage failed/);
  });
});
