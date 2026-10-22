'use strict';
// Build output only; source files and media must never be passed here.
const fs = require('node:fs');
const path = require('node:path');
const [directory, buildRoot] = process.argv.slice(2);
if (!directory || !buildRoot || !path.isAbsolute(buildRoot) || buildRoot.length < 8) {
  throw new Error('usage: sanitize-build-paths.cjs <packaged-web-directory> <absolute-build-root>');
}
let changed = 0;
function visit(directory) {
  for (const item of fs.readdirSync(directory, { withFileTypes: true })) {
    const file = path.join(directory, item.name);
    if (item.isSymbolicLink()) continue;
    if (item.isDirectory()) { visit(file); continue; }
    if (!/\.(?:js|json|map|html|txt)$/.test(item.name)) continue;
    const original = fs.readFileSync(file, 'utf8');
    const sanitized = original.split(buildRoot).join('/build/AIPlayer');
    if (original !== sanitized) { fs.writeFileSync(file, sanitized); changed++; }
  }
}
visit(directory);
console.log(`Neutralized build paths in ${changed} files`);
