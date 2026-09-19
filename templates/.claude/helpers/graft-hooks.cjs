#!/usr/bin/env node
// Locates @nanonets/graft's Claude Code entry points and runs the hook named on the
// command line. graft-statusline.cjs reuses the resolver. Does nothing until the
// project has a graft/ index, so unindexed projects pay only Node's start-up.
const path = require('path');
const fs = require('fs');
const os = require('os');
const { pathToFileURL } = require('url');
const { execSync } = require('child_process');
const dir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
const indexed = fs.existsSync(path.join(dir, 'graft'));

// Resolve dist/claude dir of @nanonets/graft from base
function fromPkg(base) {
  try {
    const pkg = require.resolve('@nanonets/graft/package.json', { paths: [base] });
    return path.join(path.dirname(pkg), 'dist', 'claude');
  } catch { return null; }
}

// Where `npx -y`, the way the harness runs Graft, keeps its packages
function npxCaches() {
  const root = process.platform === 'win32'
    ? path.join(process.env.LOCALAPPDATA || '', 'npm-cache', '_npx')
    : path.join(os.homedir(), '.npm', '_npx');
  try {
    return fs.readdirSync(root)
      .map((h) => path.join(root, h, 'node_modules', '@nanonets', 'graft'))
      .filter((p) => fs.existsSync(path.join(p, 'package.json')))
      .map((p) => path.join(p, 'dist', 'claude'));
  } catch { return []; }
}

// A user-level prefix (npm config set prefix ...) moves the global root
function npmrcPrefix() {
  try {
    const m = fs.readFileSync(path.join(os.homedir(), '.npmrc'), 'utf8').match(/^\s*prefix\s*=\s*(.+?)\s*$/m);
    return m ? [fromPkg(m[1]), fromPkg(path.join(m[1], 'lib'))] : [];
  } catch { return []; }
}

// Last resort: ask npm, which costs a process spawn
function globalRoot() {
  try {
    const root = execSync('npm root -g', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    return root || null;
  } catch { return null; }
}

function versionOf(distClaude) {
  try {
    return JSON.parse(fs.readFileSync(path.join(distClaude, '..', '..', 'package.json'), 'utf8')).version || null;
  } catch { return null; }
}

function newer(a, b) {
  if (!a) return false;
  if (!b) return true;
  const p = (v) => String(v).split('-')[0].split('.').map((n) => Number(n) || 0);
  const pa = p(a), pb = p(b);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d !== 0) return d > 0;
  }
  return false;
}

function best(dirs, name) {
  let bestDir = null, bestVer = null;
  for (const d of dirs) {
    if (!d || !fs.existsSync(path.join(d, name))) continue;
    const v = versionOf(d);
    if (bestDir === null || newer(v, bestVer)) { bestDir = d; bestVer = v; }
  }
  return bestDir;
}

function entry(name) {
  const cheap = [
    fromPkg(dir),
    fromPkg(path.join(path.dirname(process.execPath), '..', 'lib')),            // npm -g on Linux and macOS
    fromPkg(path.dirname(process.execPath)),                                     // npm -g when the prefix is Node's own directory (Windows)
    process.env.APPDATA ? fromPkg(path.join(process.env.APPDATA, 'npm')) : null, // npm -g default on Windows
    ...npmrcPrefix(),
    ...npxCaches(),
  ];
  const hit = best(cheap, name);
  if (hit) return path.join(hit, name);
  const gr = globalRoot();
  const global = gr && path.join(gr, '@nanonets', 'graft', 'dist', 'claude');
  if (global && fs.existsSync(path.join(global, name))) return path.join(global, name);
  return path.join(dir, 'dist', 'claude', name);
}

module.exports = { entry, indexed };

if (require.main === module && indexed) {
  import(pathToFileURL(entry('hooks.js')).href).then((m) => m.main(process.argv[2])).catch(() => { /* graft unavailable — no-op */ });
}
