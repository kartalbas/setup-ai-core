// What the review verdicts on the plan issues of a board say about each builder setup, counted, never
// written by a model. lib/status.mjs prints the lines; bin/status.sh reads the threads.
//
// A verdict counts when it is a comment whose first line is `REVIEW <area>: GO` or `REVIEW <area>: NO` and
// whose second line names who reviewed and who built (skills/person-in-charge/briefs/review.md):
//
//   Reviewer: <name> (<model>, <effort>). Builder: <name> (<model>, <effort>).
//
// The verdicts are counted per builder model and effort. What the count does not cover is named, never read
// as a zero: a comment that is no supported verdict shape, a NO that only asks for a full review, a repost,
// two verdicts that contradict each other, a plan issue whose thread could not be read.

const DAY = 86400;
const REVIEW = /^REVIEW (\S.*): (GO|NO)$/;
const IDENTITY = /^Reviewer: (\S+) \(([^,()]+), ([^,()]+)\)\. Builder: (\S+) \(([^,()]+), ([^,()]+)\)\.$/;
// Shapes that name a verdict or a check but are not the one this counts
const OTHER_SHAPE = /^(REVIEW\b|RE-CHECK\b|PLAN CHECK\b|VERDICT:)/;
const SECTION = /^(REPAIRED|FINDINGS|CRITERIA|TESTS|NOTES):/;

const items = (lines, section) => {
  const at = lines.findIndex((l) => l.startsWith(`${section}:`));
  if (at < 0) return [];
  const found = [lines[at].slice(section.length + 1).trim()];
  for (let i = at + 1; i < lines.length && !SECTION.test(lines[i]); i++) found.push(lines[i].trim());
  return found.filter((l) => l !== '' && !/^none$/i.test(l)).map((l) => l.replace(/^-\s*/, ''));
};

// A comment as a verdict, or why it is none: {verdict} | {unsupported: true} | null (prose, no verdict at all)
function read(comment) {
  const lines = String(comment.body || '').replace(/\r/g, '').split('\n');
  const first = REVIEW.exec(lines[0].trimEnd());
  if (!first) return OTHER_SHAPE.test(lines[0]) ? { unsupported: true } : null;
  const identity = IDENTITY.exec((lines[1] || '').trimEnd());
  const builder = identity && identity[5] !== 'unknown' && identity[6] !== 'unknown' ? { model: identity[5], effort: identity[6] } : null;
  const findings = items(lines, 'FINDINGS');
  return {
    area: first[1], result: first[2], builder,
    sessions: identity ? `${identity[1]} ${identity[4]}` : null,
    fullReview: first[2] === 'NO' && findings.length > 0 && findings.every((f) => f.startsWith('needs a full review:')),
    repaired: items(lines, 'REPAIRED').length > 0,
    text: lines.join('\n'),
  };
}

// threads: [{repository, number, failed?: reason, comments?: [{created_at, body}]}], one for each plan issue
export function tally({ threads, now, days }) {
  const since = now - days * DAY;
  const setups = new Map();
  const unattributed = { go: 0, no: 0, repaired: 0 };
  const left = { fullReview: 0, reposts: 0, conflicting: 0, unsupported: 0 };
  const unreadable = [];
  const seen = new Map();
  let planIssuesRead = 0;
  for (const thread of threads) {
    if (thread.failed !== undefined) { unreadable.push(`${thread.repository}#${thread.number} (${thread.failed})`); continue; }
    planIssuesRead++;
    for (const comment of thread.comments || []) {
      const verdict = read(comment);
      if (!verdict) continue;
      const at = Date.parse(comment.created_at) / 1000;
      // A verdict shape whose time cannot be read is not in the interval by any proof
      if (Number.isFinite(at) && (at < since || at > now)) continue;
      if (verdict.unsupported || !Number.isFinite(at)) { left.unsupported++; continue; }
      if (verdict.fullReview) { left.fullReview++; continue; }
      const identity = `${thread.repository}#${thread.number} ${verdict.area} ${verdict.sessions || verdict.text}`;
      const earlier = seen.get(identity);
      if (!earlier) seen.set(identity, { ...verdict, conflicting: false });
      else if (earlier.result === verdict.result) left.reposts++;
      else earlier.conflicting = true;
    }
  }
  let counted = 0;
  for (const verdict of seen.values()) {
    if (verdict.conflicting) { left.conflicting++; continue; }
    counted++;
    const key = verdict.builder ? `${verdict.builder.model} ${verdict.builder.effort}` : null;
    if (key !== null && !setups.has(key)) setups.set(key, { go: 0, no: 0, repaired: 0 });
    const into = key === null ? unattributed : setups.get(key);
    if (verdict.result === 'NO') into.no++;
    else { into.go++; if (verdict.repaired) into.repaired++; }
  }
  return { planIssues: threads.length, planIssuesRead, unreadable, setups, unattributed, left, counted };
}

const noun = (n, one, many) => `${n} ${n === 1 ? one : many}`;

// The lines of the page, led by the interval and what was read
export function lines({ result, now, days, board, when }) {
  const head = `reviews ${days} days to ${when(now)} on board ${board}: `;
  if (result.planIssues === 0) return [`${head}no plan issue (a title that starts with "Plan: packages") on this board`];
  const out = [`${head}${result.planIssuesRead} of ${result.planIssues} plan issues read, ${result.counted} verdicts counted`];
  const share = (s) => `${s.go} GO${s.repaired ? ` (${s.repaired} with REPAIRED)` : ''}, ${s.no} NO`;
  for (const [setup, s] of [...result.setups].sort((a, b) => a[0].localeCompare(b[0]))) out.push(`        ${setup}: ${share(s)}`);
  if (result.unattributed.go + result.unattributed.no) out.push(`        unattributed, with no builder named: ${share(result.unattributed)}`);
  const notCounted = [];
  if (result.left.fullReview) notCounted.push(`${result.left.fullReview} asking for a full review`);
  if (result.left.reposts) notCounted.push(`${result.left.reposts} reposted`);
  if (result.left.conflicting) notCounted.push(`${result.left.conflicting} contradicting another verdict of the same reviewer and builder`);
  if (notCounted.length) out.push(`        not counted: ${notCounted.join(', ')}`);
  const unmeasured = [];
  if (result.left.unsupported) unmeasured.push(`${noun(result.left.unsupported, 'comment', 'comments')} in a shape this does not count (RE-CHECK, PLAN CHECK, VERDICT: or a REVIEW line of another form)`);
  if (result.unreadable.length) unmeasured.push(`${noun(result.unreadable.length, 'plan issue', 'plan issues')} that could not be read, so the tally is incomplete: ${result.unreadable.join(', ')}`);
  if (unmeasured.length) out.push(`        unmeasured: ${unmeasured.join('; ')}`);
  return out;
}
