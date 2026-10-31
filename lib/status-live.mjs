// Two blocks of the default view of status, both read from git at the moment, never from a stored
// copy: where the work of each card in the testing column is live, and the worktrees the sweep keeps.
//
// TESTING: the card's work is the commit its landing record names, in the repository the work landed in, as the closer
// of the tracker reads it; where the issue holds no landing record, the newest commit on origin's default branch whose
// message names the issue (the pattern bin/status.sh hands over, issue_mention_pattern), by the time rule of issue_commits in
// lib/board.sh: a commit names the issue by its number only from the issue's createdAt on. An environment carries it from the
// first of its release tags that contains that commit. LIVE_TAGS of the config.env of the clone of the card's own
// repository names the environments and their tags, the last stage first ("prod=deploy/prod/* test=deploy/test/*"),
// and the project folder's config.env names them only for a clone that sets none. The first environment is the one
// whose release makes a proof due: a card its release carries is red, proof due, until the tracker holds a proof the
// closer of the tracker counts (below), and green, proven, from then on; a card no release of it carries yet waits for
// it. A card live on a later environment only is due for its proof there, and
// overdue once that environment has carried it longer than PROOF_HOURS of the project folder's config.env (24 unless set).
// A list that names no environment takes every release tag of the card's repository as its release, as status-sync
// reads every tag. The testing column
// is the one named testing, where finish-issue puts a card whose work has landed. An environment whose
// pattern is `landed` ("prod=landed") carries the work from its landing on the default branch: a repository
// that is live where it lands has no release tag of its own.
//
// A PROOF counts as the closer of the tracker counts it (bin/status-sync.sh, domain/workflow.mts findCurrentProof): the
// record holds the trusted "Proven on" comments that follow the landing record, and for an environment read by tags or
// `landed` any of them counts, whatever environment it names; for one read by `command`, only one that names that
// environment and follows the delivery. An environment whose value is `command`
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

// A config.env that exists and cannot be read: what stops the command that reads it, as the Bash reader does
export class ConfigUnreadable extends Error {}

// What stands after the = of a setting, as config_value_in_file of lib/common.sh reads it: what stands between
// the quotes, else up to a comment that follows a space, the spaces around it dropped
const settingValue = (raw) => {
  const text = raw.replace(/^\s+/, '');
  if (text.startsWith('"')) return text.slice(1).split('"')[0];
  if (text.startsWith("'")) return text.slice(1).split("'")[0];
  if (text.startsWith('#')) return '';
  return text.replace(/\s#.*$/, '').replace(/\s+$/, '');
};

const isLink = (file) => { try { fs.lstatSync(file); return true; } catch { return false; } };

// The value of KEY in a config.env: the last line that sets it, as the Bash reader reads it, or '' where the file is
// not there or nothing sets it; a file that is there and cannot be read throws ConfigUnreadable naming it
export function configValue(file, key) {
  let text = '';
  try { text = fs.readFileSync(file, 'utf8'); } catch (e) {
    if ((e.code === 'ENOENT' || e.code === 'ENOTDIR') && !isLink(file)) return '';
    throw new ConfigUnreadable(`${file} exists but cannot be read; fix its permissions, or remove it to take the defaults`);
  }
  let value = '';
  for (const line of text.split('\n')) {
    const m = line.replace(/\r$/, '').match(new RegExp(`^\\s*${key}\\s*=(.*)$`));
    if (m) value = settingValue(m[1]);
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
// What a list that names no environment reads: every release tag, with no environment to name
const EVERY_TAG = [{ name: '', pattern: '*' }];
const namesCommand = (envs) => envs.some((e) => e.pattern === 'command');
const liveRelease = path.join(path.dirname(fileURLToPath(import.meta.url)), 'live-release.sh');
// The newest commit of ref in dir that names the card, by the time rule of issue_commits (lib/board.sh), or ''
const newestCommit = (dir, ref, record) => {
  const at = Math.floor(Date.parse(record.createdAt) / 1000);
  const found = git(dir, ['log', ref, '-E', '-i', `--grep=${record.pattern}`, '--format=%ct %H']).split('\n').filter(Boolean)
    .map((line) => line.split(' ')).filter(([ct]) => Number(ct) >= at).map(([ct, sha]) => ({ ct: Number(ct), sha }));
  found.sort((a, b) => b.ct - a.ct);
  return found.length ? found[0].sha : '';
};
const firstLine = (text) => `${text || ''}`.split(/\r?\n/).map((l) => l.trim()).find(Boolean) || '';

// A card's record from bin/status.sh (write_testing_records) or lib/status-testing.sh, or null where it is not one
const usable = (r) => r && typeof r === 'object' && typeof r.repository === 'string' && Number.isInteger(r.number) && typeof r.pattern === 'string'
  && typeof r.createdAt === 'string' && Number.isFinite(Date.parse(r.createdAt))
  && ['read', 'failed'].includes(r.context) && typeof r.reason === 'string' && typeof r.landingClone === 'string'
  && Array.isArray(r.proofs) && r.proofs.every((p) => p && typeof p.environment === 'string' && typeof p.createdAt === 'string' && Number.isFinite(Date.parse(p.createdAt)))
  && (r.context === 'failed' ? r.landing === null
    : r.landing === null || (r.landing && ['repository', 'commit', 'createdAt'].every((k) => typeof r.landing[k] === 'string' && r.landing[k])));

// testing({ folder, cards, cols, liveTags, proofHours, now, records }): { lines, unknown }, the lines of the TESTING
// block, none where the board has no testing column, and how many cards it could not tell. A card is
// { key, repo (owner/name, or null where it names none), number, title, status }. records maps "<owner/repo>#<number>"
// to the record bin/status.sh wrote for the card. configFile names the project folder's config.env, for its messages only.
//
// A card is read against the first environment of its list: { live } there is red until a proof is counted and green after,
// { notLive } waits for that release. WHICH LIST OF ENVIRONMENTS A CARD IS READ AGAINST. A landing clone whose own LIVE_TAGS names an environment `command`
// is read by that whole list, its tags and `landed` included: the landing the tracker holds for the card, the delivery
// the clone's reader answers (lib/live-release.sh) and the commits of that clone. Every other card is read by the
// LIVE_TAGS of the clone of its own repository where that names an environment, else by the project folder's list, and by the
// landing record's commit in the clone its work landed in, as status-sync reads it; with no landing record, by the newest
// commit on the default branch of its own repository that names the issue. A `command` of the
// project folder's list is no reader of a clone that did not declare it. A card whose landing or delivery could not be read is
// unknown: nothing stands in for what was not read, and the counts add up to the cards.
export function testing({ folder, cards, cols, liveTags, proofHours, now, records = new Map(), configFile = '' }) {
  const column = cols.find((c) => c.toLowerCase() === 'testing');
  if (!column) return { lines: [], unknown: 0 };
  const mine = cards.filter((c) => c.status.toLowerCase() === column.toLowerCase());
  if (!mine.length) return { lines: [], unknown: 0 };
  const out = [];
  const folderList = parseEnvironments(liveTags);
  for (const word of folderList.bad) out.push(`  LIVE_TAGS of ${configFile || path.join(folder, '.ai-core', 'config.env')} has '${word}', which is no <environment>=<tag pattern>; it is left out`);
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
          const releasedAt = Date.parse(answer.delivered.releasedAt) / 1000;
          return { live: { n, env: env.name, tag: `${answer.delivered.source}, ${answer.delivered.releasedAt}`, since: now - releasedAt, delivery: releasedAt } };
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
    const [first] = envs;
    // A pattern that no tag of the repository matches is named, as status-sync names it: the card cannot be released by waiting
    let noTag = false;
    if (first.pattern !== 'command' && first.pattern !== 'landed') { try { noTag = git(repo.dir, ['tag', '--list', first.pattern]).trim() === ''; } catch { noTag = false; } }
    return { notLive: first, noTag, tagRepo: repoName };
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
      if (!isAncestor(repo.dir, sha, repo.ref)) return result('notLive', { command: true, notLive: declared.envs[0] });
      return result('walked', { command: true, ...walk({ envs: declared.envs, repo, repoName: landingRepo, sha, command: true, card }) });
    }
    // Every other card: the list of the clone of its own repository where that names an environment, else the project folder's;
    // its work is the landing record's commit in the clone it landed in, as status-sync reads it, and where the issue holds
    // no landing record the newest commit of its own repository that names it
    const ownRepo = repoOf(card.repo);
    if (!ownRepo || !ownRepo.ref) return result('noCheckout');
    ownRepo.readByTags = true;
    const set = declarationOf(ownRepo.dir);
    const list = set.envs.length ? set : folderList;
    const repoName = landingRepo || card.repo;
    const repo = record.landing ? repoOf(landingRepo, landingDir) : ownRepo;
    if (!repo || !repo.ref) return result('noCheckout');
    repo.readByTags = true;
    usedLists.set(list === folderList ? '' : card.repo, list);
    let sha = '';
    if (record.landing) sha = record.landing.commit;
    else { try { sha = newestCommit(repo.dir, repo.ref, record); } catch { /* no log, no landing commit */ } }
    if (!sha) return result('noCommit');
    const envs = list.envs.length ? list.envs : EVERY_TAG;
    if (record.landing && !isAncestor(repo.dir, sha, repo.ref)) return result('notLive', { notLive: envs[0] });
    return result('walked', walk({ envs, repo, repoName, sha, command: false, card,
      listFile: list === folderList ? configFile : path.join(ownRepo.dir, '.ai-core', 'config.env'), readerRepo: repoName }));
  });
  // The newest proof the closer of the tracker counts for a card live on its first environment, or null
  const proofOf = (card, where) => {
    const counted = records.get(`${card.repo}#${card.number}`).proofs
      .filter((p) => where.delivery === undefined || (p.environment.toLowerCase() === where.env.toLowerCase() && Date.parse(p.createdAt) / 1000 > where.delivery))
      .sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt));
    return counted[0] || null;
  };
  const live = results.filter((r) => r.live).map((r) => ({ card: r.card, where: r.live, proof: r.live.n === 0 ? proofOf(r.card, r.live) : null }));
  const kindOf = (r) => (r.kind !== 'walked' ? r.kind : r.live ? 'live' : r.notLive ? 'notLive' : 'unknown');
  const bucket = (kind) => results.filter((r) => kindOf(r) === kind);
  const notLive = bucket('notLive'), noCommit = bucket('noCommit'), noRecord = bucket('noRecord');
  const noCheckout = bucket('noCheckout'), noLandingCheckout = bucket('noLandingCheckout'), unknown = bucket('unknown');
  // The red lines first, then the yellow, then the green; within each the first environment first, then the longest live
  const signOf = ({ where, proof }) => (where.n === 0 ? (proof ? '🟢' : '🔴') : where.since > due ? '🔴' : '🟡');
  const signRank = { '🔴': 0, '🟡': 1, '🟢': 2 };
  live.sort((a, b) => signRank[signOf(a)] - signRank[signOf(b)] || a.where.n - b.where.n || b.where.since - a.where.since);
  notLive.sort((a, b) => a.notLive.name.localeCompare(b.notLive.name) || a.notLive.pattern.localeCompare(b.notLive.pattern) || a.card.key.localeCompare(b.card.key));

  const mixed = results.some((r) => r.command);
  // The live counts: per list a card was read against, the project folder's first, then the clones' in the order of their repositories,
  // each environment by its exact name and by whether it is the first of its list or a later one; one spelling can have both
  if (!mixed) usedLists.set('', folderList);
  const lists = [...usedLists.entries()].sort(([a], [b]) => (a === '' ? -1 : b === '' ? 1 : a.localeCompare(b))).map(([, l]) => l);
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
  const released = live.filter((l) => l.where.env === '').length;
  const counts = [...liveCounts, ...(released ? [`${released} released`] : []), `${notLive.length} not live`];
  const without = mixed ? [`${noCommit.length + noRecord.length} without a landing`] : [`${noCommit.length} without a landing commit`];
  const missing = noCheckout.length + noLandingCheckout.length;
  if (missing) without.push(`${missing} without a checkout`);
  if (unknown.length) without.push(`${unknown.length} unknown`);
  out.unshift(`TESTING ${mine.length} cards in ${column}: ${[...counts, ...without].join(', ')}`);
  for (const entry of live) {
    const { card, where, proof } = entry;
    const on = where.env ? ` on ${where.env}` : '';
    let said;
    if (where.n > 0) said = `live${on} since ${age(where.since)} (${where.tag})`;
    else if (!proof) said = `proof due${on} since ${age(where.since)} (${where.tag})`;
    else said = `proven${proof.environment ? ` on ${proof.environment}` : on} ${age(Math.max(0, now - Date.parse(proof.createdAt) / 1000))} ago (${where.tag})`;
    out.push(`  ${signOf(entry)} ${fit(card.key, 26)} ${said}  ${card.title}`);
  }
  for (const { card, notLive: first, noTag, tagRepo } of notLive) {
    const none = noTag ? `, no tag of ${tagRepo} matches it` : '';
    out.push(`  ⏸ ${fit(card.key, 26)} waits for ${first.name ? `the release of ${first.name} (${first.pattern})` : `a release of ${card.repo} (every tag)`}${none}  ${card.title}`);
  }
  const keys = (list) => list.map((r) => r.card.key).join(' ');
  if (noCommit.length) out.push(`  ⏸ no commit on the default branch names it: ${keys(noCommit)}`);
  if (noRecord.length) out.push(`  ⏸ no landing record of the issue names its work: ${keys(noRecord)}`);
  if (noCheckout.length) out.push(`  ⏸ no checkout of its repository in ${folder}: ${noCheckout.map((r) => r.card.key).join(' ')}`);
  if (noLandingCheckout.length) out.push(`  ⏸ no checkout of the repository its work landed in, in ${folder}: ${noLandingCheckout.map((r) => `${r.card.key} (${r.landed})`).join(' ')}`);
  for (const r of unknown) out.push(`  ❓ unknown ${r.card.repo}#${r.card.number}: ${r.reason || r.unknown}`);
  for (const [full, r] of repos) if (r && r.failed && r.readByTags) out.push(`  fetching origin of ${full} failed: ${r.failed}; read from the refs its clone had`);
  return { lines: out, unknown: unknown.length };
}

// trees({ lines, now, workItems }): the lines of the TREES block from "<repository>\t<sweep line>" lines, none
// where the sweep keeps nothing older than a day. A worktree is keyed by the issue number its line in workItems
// (worktree path -> number) names, that of its checked-out branch where that is an issue branch, which is not always the
// number its directory is named by; one whose line has no number is keyed by its directory, as a worktree that names no
// issue is, and one with no line by the number of its directory's name.
export function trees({ lines, now, workItems = new Map() }) {
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
    const n = workItems.has(dir) ? workItems.get(dir) : (path.basename(dir).match(/^issue-(\d+)/) || [])[1];
    kept.push({ key: n ? `${repo}#${n}` : `${repo} ${path.basename(dir)}`, since: last ? now - last : Infinity, reason });
  }
  if (!kept.length && !failed.length) return [];
  kept.sort((a, b) => b.since - a.since);
  return [`TREES   ${kept.length} worktrees the sweep keeps, older than a day:`,
    ...kept.map((k) => `  ${fit(k.key, 26)} ${(k.since === Infinity ? '?' : age(k.since)).padStart(5)}  ${k.reason}`), ...failed];
}
