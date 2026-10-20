const { test } = require("node:test"),
  assert = require("node:assert/strict"),
  p = require("../policy.cjs");
test("only HTTP media without credentials", () => {
  assert.equal(
    p.mediaURL("https://example.com/a.mp4"),
    "https://example.com/a.mp4",
  );
  for (const s of [
    "file:///C:/secret",
    "javascript:alert(1)",
    "https://user:pass@example.com",
  ])
    assert.throws(() => p.mediaURL(s));
});
test("playback bounds fail closed", () => {
  for (const value of [Infinity, NaN, -1, 101, "30"])
    assert.throws(() => p.engineCommand("volume", value));
  assert.deepEqual(p.engineCommand("volume", 50), [
    "set_property",
    "volume",
    50,
  ]);
  assert.throws(() => p.engineCommand("rotation", 45));
  assert.throws(() => p.engineCommand("exec", "cmd.exe"));
});
test("commands translate to documented mpv properties", () => {
  assert.deepEqual(p.engineCommand("pause", null), ["cycle", "pause"]);
  assert.deepEqual(p.engineCommand("loop", true), [
    "set_property",
    "loop-file",
    "inf",
  ]);
  assert.deepEqual(p.engineCommand("subtitleTrack", -1), [
    "set_property",
    "sid",
    "no",
  ]);
  assert.deepEqual(p.engineCommand("frameStep"), ["frame-step"]);
});
test("rectangle and random credentials", () => {
  assert.equal(
    p.rectangle({ x: 0, y: 0, width: 600, height: 400, visible: true }).width,
    600,
  );
  assert.throws(() =>
    p.rectangle({ x: -1, y: 0, width: 0, height: 0, visible: true }),
  );
  assert.equal(p.token().length, 64);
  assert.notEqual(p.token(), p.token());
});
