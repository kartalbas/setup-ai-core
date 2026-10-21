// Two blocks of the default view of status, both read from git at the moment, never from a stored
// copy: where the work of each card in the testing column is live, and the worktrees the sweep keeps.
//
// TESTING: the card's work is the newest commit on origin's default branch whose message names the
// issue (the pattern bin/status.sh hands over, issue_mention_pattern); an environment carries it from the
// first of its release tags that contains that commit. LIVE_TAGS of the config.env of the clone of the card's own
// repository names the environments and their tags, the last stage first ("prod=deploy/prod/* test=deploy/test/*"),
// and the project folder's config.env names them only for a clone that sets none. A card live
// on the first environment is out; one live on a later environment only is due for its proof there, and
// overdue once that environment has carried it longer than PROOF_HOURS of the project folder's config.env (24 unless set). The testing column
// is the one named testing, where finish-issue puts a card whose work has landed. An environment whose
// pattern is `landed` ("prod=landed") carries the work from its landing on the default branch: a repository
// that is live where it lands has no release tag of its own. An environment whose value is `command`
// ("prod=command") is delivered by what the reader of the clone the work landed in answers
// (lib/live-release.sh); a card whose landing clone declares one is read by that clone's list, from the
// landing record the tracker holds for its issue (bin/status.sh), and shown unknown where any of it could
// not be read.
//
// A TAG'S DATE is git's creatordate: an annotated tag's own date, and for a lightweight tag the date
// of the commit it points to, because a lightweight tag stores none. A lightweight tag put on an
// older commit later, a promotion from test to prod, therefore reads as live since that commit.
//
// THE CLONE of a card's repository is the folder of the project folder whose origin is that
// repository, owner included: a card of another organisation's repository of the same name is no
// card of the local clone. Each clone is fetched once per call, without a prompt and for at most a
// minute.
//
// TREES: the lines `finish-issue --sweep --dry-run` wrote for each repository of the folder (status
// runs it, so the sweep's own rules decide what stays), the kept ones whose last
// commit is older than a day.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const DAY = 86400, HOUR = 3600;
const git = (dir, args) => execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).replace(/\r/g, '');
// What a fetch said when it failed: git's first line, or that it ran out of time
const fetchOrigin = (dir) => {
  try {
    execFileSync('git', ['-C', dir, 'fetch', '-q', '--tags', 'origin'], { encoding: 'utf8', stdio: ['ignore', 'ignore', 'pipe'],
      timeout: 60000, env: { ...process.env, GIT_TERMINAL_PROMPT: '0' } });
    return '';
  } catch (e) {
    if (e.signal) return 'no answer within a minute';
    return (`${e.stderr || ''}`.split(/\r?\n/).map((l) => l.trim()).find(Boolean)) || `git exited ${e.status}`;
  }
};
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

// THE ENVIRONMENTS OF A LIVE_TAGS VALUE, in its order: { envs: [{ name, pattern }], bad: [the words that are no <environment>=<pattern>] }
const parseEnvironments = (text) => {
  const envs = [], bad = [];
  for (const word of text.split(/\s+/).filter(Boolean)) {
    const m = word.match(/^([^=]+)=(.+)$/);
    if (m) envs.push({ name: m[1], pattern: m[2] }); else bad.push(word);
  }
  return { envs, bad };
};
const namesCommand = (envs) => envs.some((e) => e.pattern === 'command');
const liveRelease = path.join(path.dirname(fileURLToPath(import.meta.url)), 'live-release.sh');
const firstLine = (text) => `${text || ''}`.split(/\r?\n/).map((l) => l.trim()).find(Boolean) || '';

// A card's record from bin/status.sh (write_testing_records), or null where it is not one
const usable = (r) => r && typeof r === 'object' && typeof r.repository === 'string' && Number.isInteger(r.number) && typeof r.pattern === 'string'
  && ['none', 'read', 'failed'].includes(r.context) && typeof r.reason === 'string' && typeof r.landingClone === 'string'
  && (r.context === 'failed' ? r.landing === null
    : r.context === 'none' ? r.landing === null
      : r.landing === null || (r.landing && ['repository', 'commit', 'createdAt'].every((k) => typeof r.landing[k] === 'string' && r.landing[k])));

// testing({ folder, cards, cols, liveTags, proofHours, now, records }): { lines, unknown }, the lines of the TESTING
// block, none where the board has no testing column, and how many cards it could not tell. A card is
// { key, repo (owner/name, or null where it names none), number, title, status }. records maps "<owner/repo>#<number>"
// to the record bin/status.sh wrote for the card. configFile names the project folder's config.env, for its messages only.
//
// WHICH LIST OF ENVIRONMENTS A CARD IS READ AGAINST. A landing clone whose own LIVE_TAGS names an environment `command`
// is read by that whole list, its tags and `landed` included: the landing the tracker holds for the card, the delivery
// the clone's reader answers (lib/live-release.sh) and the commits of that clone. Every other card is read by the
// LIVE_TAGS of the clone of its own repository where that names an environment, else by the project folder's list, and by the
// newest commit on the default branch of its own repository that names the issue. A `command` of the
// project folder's list is no reader of a clone that did not declare it. A card whose landing or delivery could not be read is
// unknown: nothing stands in for what was not read, and the counts add up to the cards.
export function testing({ folder, cards, cols, liveTags, proofHours, now, records = new Map(), configFile = '' }) {
  const column = cols.find((c) => c.toLowerCase() === 'testing');
  if (!column) return { lines: [], unknown: 0 };
  const mine = cards.filter((c) => c.status.toLowerCase() === column.toLowerCase());
  if (!mine.length) return { lines: [], unknown: 0 };
  const out = [];
  const folderList = parseEnvironments(liveTags);
  for (const word of folderList.bad) out.push(`  LIVE_TAGS has '${word}', which is no <environment>=<tag pattern>; it is left out`);
  const due = (proofHours > 0 ? proofHours : 24) * HOUR;
  // Each repository is fetched once, so the default branch and the tags are what origin has now
  const origin = (dir) => { try { return git(dir, ['remote', 'get-url', 'origin']).trim().toLowerCase().replaceAll('\\', '/').replace(/\.git$/, ''); } catch { return ''; } };
  let dirs = null;
  const clones = new Map();
  const cloneOf = (full) => {
    if (clones.has(full)) return clones.get(full);
    const want = full.toLowerCase();
    if (!dirs) { try { dirs = fs.readdirSync(folder, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => path.join(folder, d.name)); } catch { dirs = []; } }
    const found = [path.join(folder, full.split('/')[1]), ...dirs].find((d) => { const u = origin(d); return u.endsWith(`/${want}`) || u.endsWith(`:${want}`); }) || null;
    clones.set(full, found);
    return found;
  };
  const repos = new Map();
  const repoOf = (full, known = null) => {
    if (repos.has(full)) return repos.get(full);
    const dir = known || cloneOf(full);
    let r = null;
    if (dir) {
      const failed = fetchOrigin(dir);
      let ref = '';
      for (const candidate of ['origin/HEAD', 'origin/main', 'origin/master']) {
        try { git(dir, ['rev-parse', '-q', '--verify', `${candidate}^{commit}`]); ref = candidate; break; } catch { /* the next one */ }
      }
      if (ref === 'origin/HEAD') { try { ref = git(dir, ['rev-parse', '--abbrev-ref', 'origin/HEAD']).trim(); } catch { /* stays origin/HEAD */ } }
      r = { dir, ref, failed, readByTags: false };
    }
    repos.set(full, r);
    return r;
  };
  const declarations = new Map();
  const declarationOf = (dir) => {
    if (!declarations.has(dir)) {
      const file = path.join(dir, '.ai-core', 'config.env');
      const declared = parseEnvironments(configValue(file, 'LIVE_TAGS'));
      for (const word of declared.bad) out.push(`  LIVE_TAGS of ${file} has '${word}', which is no <environment>=<tag pattern>; it is left out`);
      declarations.set(dir, declared);
    }
    return declarations.get(dir);
  };
  const deliveries = new Map();
  const deliveryOf = (dir, repo, environment) => {
    const key = [dir, repo, environment].join('\0');
    if (!deliveries.has(key)) {
      let answer;
      try {
        const said = JSON.parse(execFileSync('bash', [liveRelease, 'read', dir, repo, environment], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
        answer = said && 'delivered' in said ? { delivered: said.delivered } : { error: `the answer of ${liveRelease} for ${repo} ${environment} holds no delivered` };
      } catch (e) {
        answer = { error: firstLine(e.stderr) || `${liveRelease} gave no reason for ${repo} ${environment}` };
      }
      deliveries.set(key, answer);
    }
    return deliveries.get(key);
  };
  const isAncestor = (dir, older, newer) => {
    try { execFileSync('git', ['-C', dir, 'merge-base', '--is-ancestor', older, newer], { stdio: 'ignore' }); return true; } catch { return false; }
  };

  // The first environment of the list that is established to carry the work: { live } with where, { notLive }, or { unknown }.
  // listFile names the file the list came from, and readerRepo the repository whose clone must declare command to have it run
  const walk = ({ envs, repo, repoName, sha, command, card, listFile, readerRepo }) => {
    for (const [n, env] of envs.entries()) {
      if (env.pattern === 'command') {
        if (!command) {
          const reader = readerRepo.toLowerCase() === card.repo.toLowerCase() ? `the clone of ${readerRepo}` : `the clone of ${readerRepo}, where the work of ${card.repo}#${card.number} landed,`;
          return { unknown: `LIVE_TAGS of ${listFile || 'the project folder'} says ${env.name}=command, and ${reader} declares no command: only a clone that does can have its reader run, so ${env.name} is not read` };
        }
        const answer = deliveryOf(repo.dir, repoName, env.name);
        if (answer.error) return { unknown: answer.error };
        if (!answer.delivered) continue;
        if (isAncestor(repo.dir, sha, answer.delivered.commit)) {
          return { live: { n, env: env.name, tag: `${answer.delivered.source}, ${answer.delivered.releasedAt}`, since: now - Date.parse(answer.delivered.releasedAt) / 1000 } };
        }
        continue;
      }
      if (env.pattern === 'landed') {
        let at = now;
        try { at = Number(git(repo.dir, ['log', '-1', '--format=%ct', sha]).trim()); } catch { /* read as landed now */ }
        return { live: { n, env: env.name, tag: `landed on ${repo.ref}`, since: now - at } };
      }
      let first = '';
      try { first = git(repo.dir, ['tag', '--contains', sha, '--list', env.pattern, '--sort=creatordate', '--format=%(refname:short)%09%(creatordate:unix)']).split('\n')[0]; } catch { first = ''; }
      if (first) { const [tag, at] = first.split('\t'); return { live: { n, env: env.name, tag, since: now - Number(at) } }; }
    }
    return { notLive: true };
  };

  // Where each card stands: { kind, ... } and the list it was read against ('' the project folder's, else the repository of the clone)
  const usedLists = new Map();
  const results = mine.map((card) => {
    const result = (kind, extra = {}) => ({ card, kind, ...extra });
    if (!card.repo) return result('noCheckout');
    const record = records.get(`${card.repo}#${card.number}`);
    if (!usable(record)) return result('unknown', { reason: `the record bin/status.sh hands over for ${card.repo}#${card.number} is missing or malformed` });
    if (record.context === 'failed') return result('unknown', { reason: record.reason });
    const own = cloneOf(card.repo);
    let landingDir = null, landingRepo = null;
    if (record.landing) {
      landingRepo = record.landing.repository;
      landingDir = record.landingClone || null;
      if (!landingDir) return result('noLandingCheckout', { landed: landingRepo });
    }
    const decider = landingDir || own;
    const declared = decider ? declarationOf(decider) : null;
    if (declared && namesCommand(declared.envs)) {
      if (record.context !== 'read') return result('unknown', { reason: `the landing of ${card.repo}#${card.number} was not read from the tracker, and ${decider} declares an environment as command` });
      const listKey = landingRepo || card.repo;
      usedLists.set(listKey, declared);
      if (!record.landing) return result('noRecord', { command: true });
      const repo = repoOf(landingRepo, landingDir);
      if (!repo || !repo.ref) return result('unknown', { reason: `the clone ${landingDir} of ${landingRepo} has no default branch of origin, so no delivery of it is read`, command: true });
      if (repo.failed) return result('unknown', { reason: `fetching origin of ${landingRepo} failed: ${repo.failed}, so no delivery of it is read`, command: true });
      const sha = record.landing.commit;
      if (!isAncestor(repo.dir, sha, repo.ref)) return result('notLive', { command: true });
      return result('walked', { command: true, ...walk({ envs: declared.envs, repo, repoName: landingRepo, sha, command: true, card }) });
    }
    // Every other card: the list of the clone of its own repository where that names an environment, else the project folder's, and the commits of its own repository
    const repo = repoOf(card.repo);
    if (!repo || !repo.ref) return result('noCheckout');
    repo.readByTags = true;
    const set = declarationOf(repo.dir);
    const list = set.envs.length ? set : folderList;
    usedLists.set(list === folderList ? '' : card.repo, list);
    let sha = '';
    try { sha = git(repo.dir, ['log', repo.ref, '-E', '-i', `--grep=${record.pattern}`, '--format=%H', '-n', '1']).trim(); } catch { /* no log, no landing commit */ }
    if (!sha) return result('noCommit');
    if (!list.envs.length) return result('landed');
    return result('walked', walk({ envs: list.envs, repo, repoName: card.repo, sha, command: false, card,
      listFile: list === folderList ? configFile : path.join(repo.dir, '.ai-core', 'config.env'), readerRepo: landingRepo || card.repo }));
  });
  const live = results.filter((r) => r.live).map((r) => ({ card: r.card, where: r.live }));
  const kindOf = (r) => (r.kind !== 'walked' ? r.kind : r.live ? 'live' : r.notLive ? 'notLive' : 'unknown');
  const bucket = (kind) => results.filter((r) => kindOf(r) === kind);
  const landed = bucket('landed'), notLive = bucket('notLive'), noCommit = bucket('noCommit'), noRecord = bucket('noRecord');
  const noCheckout = bucket('noCheckout'), noLandingCheckout = bucket('noLandingCheckout'), unknown = bucket('unknown');
  live.sort((a, b) => a.where.n - b.where.n || b.where.since - a.where.since);

  const mixed = results.some((r) => r.command);
  // The live counts: per list a card was read against, the project folder's first, then the clones' in the order of their repositories,
  // each environment by its exact name and by whether it is the first of its list or a later one; one spelling can have both
  if (!mixed) usedLists.set('', folderList);
  const lists = [...usedLists.entries()].sort(([a], [b]) => (a === '' ? -1 : b === '' ? 1 : a.localeCompare(b))).map(([, l]) => l);
  const named = lists.some((l) => l.envs.length);
  const seen = new Set();
  const liveCounts = [];
  for (const list of lists) {
    for (const [n, env] of list.envs.entries()) {
      const key = `${env.name}\0${n === 0}`;
      if (seen.has(key)) continue;
      seen.add(key);
      liveCounts.push(`${live.filter((l) => l.where.env === env.name && (l.where.n === 0) === (n === 0)).length} live on ${env.name}${n ? ' only' : ''}`);
    }
  }
  let counts, without;
  if (mixed) {
    counts = [...liveCounts, ...(landed.length ? [`${landed.length} landed`] : []), `${notLive.length} not live`];
    without = [`${noCommit.length + noRecord.length} without a landing`];
  } else {
    counts = named
      ? [...liveCounts, ...(landed.length ? [`${landed.length} landed`] : []), `${notLive.length} not live`] : [`${landed.length} landed`];
    without = [`${noCommit.length} without a landing commit`];
  }
  const missing = noCheckout.length + noLandingCheckout.length;
  if (missing) without.push(`${missing} without a checkout`);
  if (unknown.length) without.push(`${unknown.length} unknown`);
  out.unshift(`TESTING ${mine.length} cards in ${column}: ${[...counts, ...without].join(', ')}`);
  if (!mixed && !named) out.push(`  LIVE_TAGS in the project folder's .ai-core/config.env names no environment, so where the work is live is not read`);
  for (const { card, where } of live) {
    const sign = where.n === 0 ? '🟢' : where.since > due ? '🔴' : '🟡';
    out.push(`  ${sign} ${fit(card.key, 26)} live on ${where.env} since ${age(where.since)} (${where.tag})  ${card.title}`);
  }
  const keys = (list) => list.map((r) => r.card.key).join(' ');
  if (landed.length) out.push(`  ⏸ landed: ${keys(landed)}`);
  if (notLive.length) out.push(`  ⏸ not live: ${keys(notLive)}`);
  if (noCommit.length) out.push(`  ⏸ no commit on the default branch names it: ${keys(noCommit)}`);
  if (noRecord.length) out.push(`  ⏸ no landing record of the issue names its work: ${keys(noRecord)}`);
  if (noCheckout.length) out.push(`  ⏸ no checkout of its repository in ${folder}: ${noCheckout.map((r) => r.card.key).join(' ')}`);
  if (noLandingCheckout.length) out.push(`  ⏸ no checkout of the repository its work landed in, in ${folder}: ${noLandingCheckout.map((r) => `${r.card.key} (${r.landed})`).join(' ')}`);
  for (const r of unknown) out.push(`  ❓ unknown ${r.card.repo}#${r.card.number}: ${r.reason || r.unknown}`);
  for (const [full, r] of repos) if (r && r.failed && r.readByTags) out.push(`  fetching origin of ${full} failed: ${r.failed}; read from the refs its clone had`);
  return { lines: out, unknown: unknown.length };
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
    // Its last touch: the last commit, or a change made since and not committed
    let last = 0;
    try {
      last = Number(git(dir, ['log', '-1', '--format=%ct', 'HEAD']).trim());
      // -z keeps a path as it is, unquoted; a rename or copy is followed by its source, which is skipped
      const items = git(dir, ['status', '--porcelain', '-z']).split('\0');
      for (let k = 0; k < items.length; k++) {
        const entry = items[k];
        if (entry.length < 4) continue;
        if (entry[0] === 'R' || entry[0] === 'C') k++;
        // A deleted file has no time of its own; its folder changed when it went
        const file = path.join(dir, entry.slice(3));
        for (const at of [file, path.dirname(file)]) {
          try { last = Math.max(last, Math.floor(fs.statSync(at).mtimeMs / 1000)); break; } catch { /* the next one */ }
        }
      }
    } catch { last = 0; }
    if (last && now - last < DAY) continue;
    const n = (path.basename(dir).match(/^issue-(\d+)/) || [])[1];
    kept.push({ key: n ? `${repo}#${n}` : `${repo} ${path.basename(dir)}`, since: last ? now - last : Infinity, reason });
  }
  if (!kept.length && !failed.length) return [];
  kept.sort((a, b) => b.since - a.since);
  return [`TREES   ${kept.length} worktrees the sweep keeps, older than a day:`,
    ...kept.map((k) => `  ${fit(k.key, 26)} ${(k.since === Infinity ? '?' : age(k.since)).padStart(5)}  ${k.reason}`), ...failed];
}
