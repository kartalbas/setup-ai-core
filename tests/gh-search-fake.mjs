// The stand-in for gh that tests/issue-list.test.sh puts on the PATH: the issue search of GitHub's GraphQL API over the
// issues in $GH_SEARCH_STATE/issues.json, every call logged to $GH_SEARCH_STATE/calls.log, one line a call, and every search
// to searches.log. It answers
// `gh api graphql --paginate -f q=<search> -f query=<graphql>` as GitHub's search does: the qualifiers repo:, org:, is:issue,
// is:open, is:closed and in:title,body, and every quoted term found, in any case, in the title or the body. An unquoted
// word is a qualifier, and one this stand-in does not know ends the call, so a word that reached the search unquoted is
// seen. A page holds $GH_SEARCH_PAGE_SIZE issues (50), --paginate prints one JSON document for each page, and at most
// $GH_SEARCH_SERVE_AT_MOST issues are served while issueCount names every match, as the 1000 of the real search.
// `gh api repos/{owner}/{repo}` answers the repository of the checkout. Shapes follow the answer of the live search read on
// 2026-10-30 for this suite; they are not a copy of the server.
//
// issues.json: {"repository": "owner/repo", "issues": [{repo, number, state, title, body, cards: [{status, priority}]}]}
//   a card holds the names of its Status and Priority, or null. "refuse": true makes a search answer 502 as a refused read does.
import fs from 'node:fs';
import path from 'node:path';

const dir = process.env.GH_SEARCH_STATE ?? '';
const args = process.argv.slice(2);
fs.appendFileSync(path.join(dir, 'calls.log'), `${args.join(' ').replace(/\n/g, ' ')}\n`);
const state = JSON.parse(fs.readFileSync(path.join(dir, 'issues.json'), 'utf8'));

if (args[0] === 'api' && args[1]?.startsWith('repos/')) {
  fs.writeSync(1, `${state.repository}\n`);
  process.exit(0);
}
if (args[0] !== 'api' || args[1] !== 'graphql') {
  fs.writeSync(2, `the stand-in does not know: ${args.join(' ')}\n`);
  process.exit(1);
}
if (state.refuse === true) {
  fs.writeSync(1, '{"message":"Bad Gateway"}\n');
  fs.writeSync(2, 'gh: Bad Gateway (HTTP 502)\n');
  process.exit(1);
}

const search = args.find((argument) => argument.startsWith('q='))?.slice(2) ?? '';
fs.appendFileSync(path.join(dir, 'searches.log'), `${search}\n`);
const lower = (text) => text.toLowerCase();
let repo;
let org;
let wantedState;
const terms = [];
for (const match of search.matchAll(/"((?:\\.|[^"\\])*)"|(\S+)/g)) {
  if (match[1] !== undefined) {
    terms.push(lower(match[1].replace(/\\(["\\])/g, '$1')));
    continue;
  }
  const word = match[2];
  if (word.startsWith('repo:')) repo = lower(word.slice(5));
  else if (word.startsWith('org:')) org = lower(word.slice(4));
  else if (word === 'is:issue' || word === 'in:title,body') continue;
  else if (word === 'is:open' || word === 'is:closed') wantedState = word.slice(3);
  else {
    fs.writeSync(2, `the stand-in does not know the qualifier ${word}\n`);
    process.exit(1);
  }
}

const found = state.issues.filter((issue) => {
  if (repo !== undefined && lower(issue.repo) !== repo) return false;
  if (org !== undefined && lower(issue.repo.split('/')[0]) !== org) return false;
  if (wantedState !== undefined && issue.state !== wantedState) return false;
  const text = lower(`${issue.title}\n${issue.body}`);
  return terms.every((term) => text.includes(term));
});
const served = found.slice(0, Number(process.env.GH_SEARCH_SERVE_AT_MOST ?? found.length));
const size = Number(process.env.GH_SEARCH_PAGE_SIZE ?? 50);
const named = (name) => (name === null || name === undefined ? null : { name });
for (let from = 0; from === 0 || from < served.length; from += size) {
  const nodes = served.slice(from, from + size).map((issue) => ({
    number: issue.number,
    title: issue.title,
    repository: { nameWithOwner: issue.repo },
    projectItems: { nodes: issue.cards.map((card) => ({ status: named(card.status), priority: named(card.priority) })) },
  }));
  const hasNextPage = from + size < served.length;
  fs.writeSync(1, `${JSON.stringify({ data: { search: { issueCount: found.length, pageInfo: { hasNextPage, endCursor: hasNextPage ? `cursor-${from + size}` : null }, nodes } } })}\n`);
}
