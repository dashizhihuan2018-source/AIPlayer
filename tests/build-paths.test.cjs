const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

test('packaged web output has neutral build roots without changing other data', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'aiplayer-path-test-'));
  try {
    const file = path.join(root, 'sample.json');
    fs.writeFileSync(file, JSON.stringify({ path: root + '/upstream/source.ts', keep: 'movie poster' }));
    const result = spawnSync(process.execPath, [path.join(__dirname, '../desktop/sanitize-build-paths.cjs'), root, root], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(fs.readFileSync(file)), { path: '/build/AIPlayer/upstream/source.ts', keep: 'movie poster' });
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
