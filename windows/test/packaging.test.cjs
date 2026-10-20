"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { getFileMatchers } = require("app-builder-lib/out/fileMatcher.js");
const config = require("../package.json").build;
test("standalone dependencies have their own mapping because builder excludes root node_modules", () => {
  const root = path.resolve(__dirname, "..");
  const mappings = getFileMatchers(
    config,
    "extraResources",
    path.join(root, "release/resources"),
    {
      defaultSrc: root,
      globalOutDir: path.join(root, "release"),
      macroExpander: (x) => x,
      customBuildOptions: {},
    },
  );
  const source = mappings.find((x) => x.from === path.join(root, "server"));
  source.prependPattern("**/*");
  assert.equal(
    source.createFilter()(path.join(root, "server/node_modules"), {
      isDirectory: () => true,
    }),
    false,
  );
  const dependencies = mappings.find(
    (x) => x.from === path.join(root, "server/node_modules"),
  );
  assert.ok(dependencies, "a second explicit mapping is mandatory");
  dependencies.prependPattern("**/*");
  assert.equal(
    dependencies.createFilter()(
      path.join(root, "server/node_modules/next/package.json"),
      { isDirectory: () => false },
    ),
    true,
  );
});
