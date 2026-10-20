"use strict";
const test = require("node:test"),
  assert = require("node:assert/strict"),
  fs = require("node:fs/promises"),
  path = require("node:path"),
  os = require("node:os"),
  net = require("node:net");
const { persistentPort } = require("../port.cjs");
test("keeps the same loopback origin across launches and fails closed on port conflicts", async () => {
  const folder = await fs.mkdtemp(
    path.join(os.tmpdir(), "aiplayer-port-test-"),
  );
  const server = net.createServer();
  try {
    const first = await persistentPort(folder);
    assert.equal(await persistentPort(folder), first);
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(first, "127.0.0.1", resolve);
    });
    await assert.rejects(persistentPort(folder), /正被占用/);
    assert.equal(
      JSON.parse(await fs.readFile(path.join(folder, "server-port.json"))).port,
      first,
    );
  } finally {
    if (server.listening) await new Promise((r) => server.close(r));
    await fs.rm(folder, { recursive: true, force: true });
  }
});
test("does not silently reset corrupt persistence configuration", async () => {
  const folder = await fs.mkdtemp(
    path.join(os.tmpdir(), "aiplayer-port-test-"),
  );
  try {
    await fs.writeFile(path.join(folder, "server-port.json"), "invalid");
    await assert.rejects(persistentPort(folder), /保留原配置/);
  } finally {
    await fs.rm(folder, { recursive: true, force: true });
  }
});
