#!/usr/bin/env node
const { pathToFileURL } = require('url');
const { entry, indexed } = require('./graft-hooks.cjs');

if (indexed) {
  import(pathToFileURL(entry('statusline.js')).href).then((m) => m.main()).catch(() => { /* graft unavailable — no-op */ });
}
