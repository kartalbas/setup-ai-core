// Whether a Claude Code session compacts in a loop, read from its transcript, for bin/watch.sh. It reads and changes
// nothing but its own state file.
//
//   node lib/watch-transcript.mjs --state FILE --file TRANSCRIPT --now EPOCH_SECONDS [--window 600] [--count 3]
//
// Two lines of the transcript tell it, as Claude Code 2.1 writes them:
//   {"type":"system","subtype":"compact_boundary","uuid":"...","timestamp":"2026-10-19T10:00:00.000Z",...}   a compaction
//   {"type":"assistant","isApiErrorMessage":true,"timestamp":"...","message":{"content":[{"type":"text","text":"Autocompact is thrashing: ..."}]}}
// The words of the second one inside an ordinary message count as nothing.
//
// Each call reads the transcript on from where the last call stopped and keeps the events of the last --window seconds
// in the state file; a first call reads back far enough to see that window, and a transcript that shrank or is another
// file (its inode changed) is read anew. A partial last line waits for the next call.
//
// stdout and exit status: nothing, 0: the session does not thrash; one line, 10: it does, saying which sign; one line,
// 1: the transcript could not be read or is not what it should be, and the line says why.

import fs from 'node:fs';
import path from 'node:path';

const A = { window: '600', count: '3' };
for (let i = 2; i < process.argv.length; i += 2) A[process.argv[i].replace(/^--/, '')] = process.argv[i + 1];
const WINDOW = Number(A.window), COUNT = Number(A.count), NOW = Number(A.now);
const STEP = 1 << 20;
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;

const stop = (status, line) => { if (line) process.stdout.write(`${line}\n`); process.exit(status); };
for (const k of ['state', 'file', 'now']) if (!A[k]) stop(1, `error: --${k} is required`);
if (![WINDOW, COUNT, NOW].every(Number.isFinite)) stop(1, 'error: --now, --window and --count take numbers');

let state = null;
try { state = JSON.parse(fs.readFileSync(A.state, 'utf8')); } catch { state = null; }

let fd;
try { fd = fs.openSync(A.file, 'r'); } catch (e) { stop(1, `the transcript ${A.file} cannot be read: ${e.code || e.message}`); }
const stat = fs.fstatSync(fd);

// The seconds of a record's timestamp, or null where it has none that can be used
const secondsOf = (record) => (typeof record.timestamp === 'string' && ISO.test(record.timestamp) ? Date.parse(record.timestamp) / 1000 : null);
const parse = (line) => { try { const r = JSON.parse(line); return r && typeof r === 'object' ? r : undefined; } catch { return undefined; } };

// Where to start reading: the line boundary after the last line older than the window. Walks back in steps and stops at
// the first step that holds such a line; a line cut by the edge of a step is not read, a line that fills a step is passed.
function startOffset(cutoff) {
  for (let at = Math.max(0, stat.size - STEP); ; at = Math.max(0, at - STEP)) {
    const buffer = Buffer.alloc(Math.min(STEP, stat.size - at));
    fs.readSync(fd, buffer, 0, buffer.length, at);
    const text = buffer.toString('latin1');
    const first = at === 0 ? 0 : text.indexOf('\n') + 1;
    if (at !== 0 && first === 0) continue;
    let keep = -1;
    for (let from = first, end; (end = text.indexOf('\n', from)) >= 0; from = end + 1) {
      const record = parse(text.slice(from, end));
      const seconds = record ? secondsOf(record) : null;
      if (seconds !== null && seconds < cutoff) keep = end + 1;
    }
    if (keep >= 0) return at + keep;
    if (at === 0) return 0;
  }
}

if (!state || state.ino !== stat.ino || stat.size < state.offset) {
  state = { ino: stat.ino, offset: stat.size === 0 ? 0 : startOffset(NOW - WINDOW), compactions: {}, diagnostic: null };
}

// Read on from the offset, line by line; the offset moves past a line only once it is complete and has been understood
let failure = null;
const chunk = Buffer.alloc(STEP);
let pending = Buffer.alloc(0);
for (let n; failure === null && (n = fs.readSync(fd, chunk, 0, chunk.length, state.offset + pending.length)) > 0;) {
  pending = Buffer.concat([pending, chunk.subarray(0, n)]);
  for (let end; failure === null && (end = pending.indexOf(0x0a)) >= 0;) {
    const text = pending.subarray(0, end).toString('utf8').replace(/\r$/, '');
    const length = end + 1;
    pending = pending.subarray(length);
    if (text.trim() === '') { state.offset += length; continue; }
    const record = parse(text);
    if (record === undefined) { failure = `the transcript ${A.file} holds a complete line that is not JSON, at byte ${state.offset}`; break; }
    const compaction = record.type === 'system' && record.subtype === 'compact_boundary';
    const content = record.message && Array.isArray(record.message.content) ? record.message.content[0] : undefined;
    const diagnostic = record.type === 'assistant' && record.isApiErrorMessage === true
      && content && content.type === 'text' && typeof content.text === 'string' && content.text.startsWith('Autocompact is thrashing');
    if (compaction || diagnostic) {
      const seconds = secondsOf(record);
      if (seconds === null) { failure = `the transcript ${A.file} holds a ${compaction ? 'compaction' : 'thrashing diagnostic'} with no usable timestamp, at byte ${state.offset}`; break; }
      if (compaction) {
        if (typeof record.uuid !== 'string' || record.uuid === '') { failure = `the transcript ${A.file} holds a compaction with no uuid, at byte ${state.offset}`; break; }
        state.compactions[record.uuid] = seconds;
      } else state.diagnostic = Math.max(state.diagnostic ?? 0, seconds);
    }
    state.offset += length;
  }
}
fs.closeSync(fd);

for (const [uuid, seconds] of Object.entries(state.compactions)) if (seconds <= NOW - WINDOW) delete state.compactions[uuid];
if (state.diagnostic !== null && state.diagnostic <= NOW - WINDOW) state.diagnostic = null;
const temporary = `${A.state}.${process.pid}.tmp`;
fs.mkdirSync(path.dirname(A.state), { recursive: true });
fs.writeFileSync(temporary, JSON.stringify(state));
fs.renameSync(temporary, A.state);

if (failure !== null) stop(1, failure);
if (state.diagnostic !== null) stop(10, `Claude Code wrote "Autocompact is thrashing" ${Math.max(0, Math.round(NOW - state.diagnostic))} seconds ago`);
const count = Object.keys(state.compactions).length;
if (count >= COUNT) stop(10, `${count} compactions in the last ${WINDOW} seconds`);
stop(0);
