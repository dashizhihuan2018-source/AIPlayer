const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const root = join(__dirname, '..');
test('immersive host installs native title-bar dragging after web view setup', () => {
  const source = readFileSync(join(root, 'desktop/main.swift'), 'utf8');
  assert.match(source, /titlebarDrag = NativeTitlebarDragController\(window: window\)/);
});
test('native playback owns and releases a display-sleep assertion', () => {
  const source = readFileSync(join(root, 'desktop/NativePlayer.swift'), 'utf8');
  assert.match(source, /playbackPower\.update/);
  assert.match(source, /playbackPower\.release\(\)/);
});
