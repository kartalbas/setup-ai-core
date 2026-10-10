// Two blocks of the default view of status, both read from git at the moment, never from a stored
// copy: where the work of each card in the testing column is live, and the worktrees the sweep keeps.
//
// TESTING: the card's work is the newest commit on origin's default branch whose subject names the
// issue (#N); an environment carries it from the first of its release tags that contains that
// commit. LIVE_TAGS of the project's config.env names the environments and their tags, the one that
// counts first ("prod=deploy/prod/* test=deploy/test/*"); a card the first environment has carried
// longer than PROOF_HOURS (24 unless set) is due. The testing column is the one after implementing,
// where finish-issue puts a card whose work has landed.
//
// TREES: the lines `finish-issue --sweep --dry-run` wrote for each repository of the folder (the
// twins of status run it, so the sweep's own rules decide what stays), the kept ones whose last
// commit is older than a day.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const DAY = 86400, HOUR = 3600;
const git = (dir, args) => execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).replace(/\r/g, '');
const age = (s) => (s < 2 * DAY ? `${Math.floor(s / HOUR)} h` : `${Math.floor(s / DAY)} d`);
const fit = (s, n) => (s.length > n ? s.slice(0, n - 1) + '…' : s.padEnd(n));

// The value of KEY in a config.env: the last line that sets it, without a comment, quotes and the
// spaces around, or '' where nothing sets it
export function configValue(file, key) {
  let text = '';
  try { text = fs.readFileSync(file, 'utf8'); } catch { return ''; }
  let value = '';
  for (const line of text.split('\n')) {
    const m = line.replace(/\r$/, '').match(new RegExp(`^\\s*${key}\\s*=(.*)$`));
    if (m) value = m[1].split('#')[0].trim().replace(/^["']|["']$/g, '').trim();
  }
  return value;
}

// testing({ folder, cards, cols, liveTags, proofHours, now }): the lines of the TESTING block, none
// where the board has no column after implementing. A card is { key, repo, number, title, status }.
export function testing({ folder, cards, cols, liveTags, proofHours, now }) {
  const i = cols.findIndex((c) => c.toLowerCase() === 'implementing');
  const column = i >= 0 && i + 2 < cols.length ? cols[i + 1] : null;
  if (!column) return [];
  const mine = cards.filter((c) => c.status.toLowerCase() === column.toLowerCase());
  if (!mine.length) return [];
  const out = [];
  const envs = [];
  for (const word of liveTags.split(/\s+/).filter(Boolean)) {
    const m = word.match(/^([^=]+)=(.+)$/);
    if (m) envs.push({ name: m[1], pattern: m[2] });
    else out.push(`  LIVE_TAGS has '${word}', which is no <environment>=<tag pattern>; it is left out`);
  }
  const due = (proofHours > 0 ? proofHours : 24) * HOUR;
  // Each repository is fetched once, so the default branch and the tags are what origin has now
  const repos = new Map();
  const repoOf = (name) => {
    if (repos.has(name)) return repos.get(name);
    const dir = path.join(folder, name);
    let r = null;
    if (fs.existsSync(path.join(dir, '.git'))) {
      let fetched = true;
      try { git(dir, ['fetch', '-q', '--tags', 'origin']); } catch { fetched = false; }
      let ref = '';
      for (const candidate of ['origin/HEAD', 'origin/main', 'origin/master']) {
        try { git(dir, ['rev-parse', '-q', '--verify', `${candidate}^{commit}`]); ref = candidate; break; } catch { /* the next one */ }
      }
      if (ref === 'origin/HEAD') { try { ref = git(dir, ['rev-parse', '--abbrev-ref', 'origin/HEAD']).trim(); } catch { /* stays origin/HEAD */ } }
      r = { dir, ref, fetched };
    }
    repos.set(name, r);
    return r;
  };
  const live = [], notLive = [], noCommit = [], noCheckout = [];
  for (const card of mine) {
    const repo = repoOf(card.repo);
    if (!repo || !repo.ref) { noCheckout.push(card.key); continue; }
    const named = new RegExp(`#${card.number}(?![0-9])`);
    let sha = '';
    try {
      for (const line of git(repo.dir, ['log', repo.ref, '-E', `--grep=#${card.number}([^0-9]|$)`, '--format=%H%x09%s']).split('\n')) {
        const [h, subject] = line.split('\t');
        if (h && named.test(subject || '')) { sha = h; break; }
      }
    } catch { /* no log, no landing commit */ }
    if (!sha) { noCommit.push(card.key); continue; }
    let where = null;
    for (const [n, env] of envs.entries()) {
      let first = '';
      try { first = git(repo.dir, ['tag', '--contains', sha, '--list', env.pattern, '--sort=creatordate', '--format=%(refname:short)%09%(creatordate:unix)']).split('\n')[0]; } catch { first = ''; }
      if (first) { const [tag, at] = first.split('\t'); where = { n, env: env.name, tag, since: now - Number(at) }; break; }
    }
    if (where) live.push({ card, where }); else notLive.push(card.key);
  }
  live.sort((a, b) => a.where.n - b.where.n || b.where.since - a.where.since);
  const counts = envs.map((e, n) => `${live.filter((l) => l.where.n === n).length} live on ${e.name}${n ? ' only' : ''}`);
  out.unshift(`TESTING ${mine.length} cards in ${column}: ${[...counts, `${notLive.length} not live`, `${noCommit.length} without a landing commit`].join(', ')}`);
  if (!envs.length) out.push(`  LIVE_TAGS in .ai-core/config.env names no environment, so where the work is live is not read`);
  for (const { card, where } of live) {
    const sign = where.n > 0 ? '🟡' : where.since > due ? '🔴' : '🟢';
    out.push(`  ${sign} ${fit(card.key, 26)} live on ${where.env} since ${age(where.since)} (${where.tag})  ${card.title}`);
  }
  if (notLive.length) out.push(`  ⏸ not live: ${notLive.join(' ')}`);
  if (noCommit.length) out.push(`  ⏸ no commit on the default branch names it: ${noCommit.join(' ')}`);
  if (noCheckout.length) out.push(`  ⏸ no checkout of its repository in ${folder}: ${noCheckout.join(' ')}`);
  const unreached = [...repos.entries()].filter(([, r]) => r && !r.fetched).map(([n]) => n);
  if (unreached.length) out.push(`  origin not reached, so read from the refs this clone had: ${unreached.join(' ')}`);
  return out;
}

// trees({ lines, now }): the lines of the TREES block from "<repository>\t<sweep line>" lines, none
// where the sweep keeps nothing older than a day
export function trees({ lines, now }) {
  const kept = [], failed = [];
  for (const line of lines) {
    const [repo, said] = line.split('\t');
    if (said === undefined) continue;
    if (said.startsWith('error: ')) { failed.push(`  ${repo}: the sweep could not run: ${said.slice(7)}`); continue; }
    const m = said.match(/^worktree (.*): (.*), stays$/);
    if (!m) continue;
    const [, dir, reason] = m;
    let last = 0;
    try { last = Number(git(dir, ['log', '-1', '--format=%ct', 'HEAD']).trim()); } catch { last = 0; }
    if (!last || now - last < DAY) continue;
    const n = (path.basename(dir).match(/^issue-(\d+)/) || [])[1];
    kept.push({ key: `${repo}#${n}`, since: now - last, reason });
  }
  if (!kept.length && !failed.length) return [];
  kept.sort((a, b) => b.since - a.since);
  return [`TREES   ${kept.length} worktrees the sweep keeps, older than a day:`,
    ...kept.map((k) => `  ${fit(k.key, 26)} ${age(k.since).padStart(5)}  ${k.reason}`), ...failed];
}
