// Headless runner for CI and for agents, loading the exact same test.js the
// browser page does. Shims the three globals the browser provides for free.
//
//   node web/run-tests.js
//
// The browser page (test.html) remains the primary runner -- it is what a
// contributor without node opens. This exists so the suite has an exit code.
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const dir = __dirname;
const read = (f) => fs.readFileSync(path.join(dir, f), 'utf8');

// Minimal DOM: reportResults writes into two elements and nothing else.
const stub = () => ({
  textContent: '', className: '', children: [],
  appendChild(c) { this.children.push(c); }
});
const summary = stub(), results = stub();

const sandbox = {
  TextEncoder,
  console,
  document: {
    getElementById: (id) => (id === 'summary' ? summary : results),
    createElement: stub
  },
  // corpus.json is the only fetch the suite makes; serve it from disk so the
  // headless path exercises the same code as the browser rather than skipping it.
  fetch: (url) => Promise.resolve({
    ok: true,
    json: () => Promise.resolve(JSON.parse(read(url)))
  })
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;

const ctx = vm.createContext(sandbox);
['vendor/qrcode.js', 'parse.js', 'sevenTV.js', 'payload.js', 'test.js']
  .forEach((f) => vm.runInContext(read(f), ctx, { filename: f }));

sandbox.__onTestsDone = (failures, all) => {
  all.filter((r) => !r.ok)
     .forEach((r) => console.log('  ✗ ' + r.name + ' — ' + r.msg));
  console.log(summary.textContent);
  process.exitCode = failures === 0 ? 0 : 1;
};
