#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const [depsArchive, sourceDir, licenseDir, cacheDir] = process.argv.slice(2);
if (!depsArchive || !sourceDir || !licenseDir || !cacheDir) {
  console.error('usage: collect-native-sources.js <deps-scripts.tar.gz> <source-dir> <license-dir> <cache-dir>');
  process.exit(2);
}

for (const directory of [sourceDir, licenseDir, cacheDir]) fs.mkdirSync(directory, { recursive: true });

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { stdio: 'inherit', ...options });
  if (result.status !== 0) throw new Error(`${command} exited ${result.status}`);
}

function sha256(file) {
  const hash = crypto.createHash('sha256');
  hash.update(fs.readFileSync(file));
  return hash.digest('hex');
}

function expand(value, variables) {
  let result = value;
  for (let pass = 0; pass < 8; pass += 1) {
    const next = result.replace(/\$\{([A-Z0-9_]+)\}/g, (_, key) => variables[key] ?? `\${${key}}`);
    if (next === result) return result;
    result = next;
  }
  return result;
}

function safeName(value) {
  return value.toLowerCase().replace(/[^a-z0-9._-]+/g, '-');
}

function collectNotices(root, project) {
  const destination = path.join(licenseDir, safeName(project));
  let count = 0;
  function walk(directory) {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      if (entry.name === '.git' || entry.name === 'build') continue;
      const absolute = path.join(directory, entry.name);
      if (entry.isDirectory()) { walk(absolute); continue; }
      const name = entry.name.toLowerCase();
      if (!/^(license|copying|copyright|notice|authors)(\..*)?$/.test(name)
          && !['ftl.txt', 'ofl.txt', 'patents'].includes(name)) continue;
      const stat = fs.statSync(absolute);
      if (stat.size > 2_000_000) continue;
      fs.mkdirSync(destination, { recursive: true });
      const relative = path.relative(root, absolute).replaceAll(path.sep, '__');
      fs.copyFileSync(absolute, path.join(destination, relative));
      count += 1;
    }
  }
  walk(root);
  if (!count) throw new Error(`No license/copyright notice found for ${project}`);
}

function downloadPinnedSource(project, url) {
  const urlName = path.basename(new URL(url).pathname) || `${safeName(project)}.tar.gz`;
  const suffix = /\.(tar\.(gz|xz|bz2)|tgz|zip)$/i.test(urlName) ? '' : '.tar.gz';
  const cached = path.join(cacheDir, `${safeName(project)}-${urlName}${suffix}`);
  if (!fs.existsSync(cached)) {
    run('curl', [
      '--fail', '--location', '--retry', '8', '--retry-all-errors', '--retry-delay', '2',
      '--connect-timeout', '20', '--speed-limit', '1024', '--speed-time', '60',
      '--output', cached, url,
    ]);
  }
  const delivered = path.join(sourceDir, path.basename(cached));
  fs.copyFileSync(cached, delivered);
  const extracted = fs.mkdtempSync(path.join(temp, `${safeName(project)}-`));
  run('tar', ['-xf', cached, '-C', extracted]);
  collectNotices(extracted, project);
  return `${path.basename(delivered)}  ${sha256(delivered)}`;
}

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'aiplayer-native-source-'));
try {
  const scriptsRoot = path.join(temp, 'scripts');
  fs.mkdirSync(scriptsRoot);
  run('tar', ['-xzf', depsArchive, '-C', scriptsRoot]);
  const checkout = fs.readdirSync(scriptsRoot).map((name) => path.join(scriptsRoot, name))
    .find((candidate) => fs.statSync(candidate).isDirectory());
  if (!checkout) throw new Error('Dependency build-script archive has no root directory');
  const envText = fs.readFileSync(path.join(checkout, 'versions.env'), 'utf8');
  const variables = {};
  for (const line of envText.split(/\r?\n/)) {
    const match = line.match(/^([A-Z0-9_]+)="([^"]*)"/);
    if (match) variables[match[1]] = expand(match[2], variables);
  }
  for (const [key, rawURL] of Object.entries(variables)) {
    if (!key.endsWith('_URL')) continue;
    const project = key.slice(0, -4);
    const expected = variables[`${project}_SHA256`];
    if (!expected) throw new Error(`Missing checksum for ${project}`);
    const url = expand(rawURL, variables);
    const urlName = path.basename(new URL(url).pathname) || `${safeName(project)}.tar.gz`;
    const cached = path.join(cacheDir, `${safeName(project)}-${urlName}`);
    if (!fs.existsSync(cached) || sha256(cached) !== expected) {
      if (fs.existsSync(cached)) fs.unlinkSync(cached);
      run('curl', [
        '--fail', '--location', '--retry', '8', '--retry-all-errors', '--retry-delay', '2',
        '--connect-timeout', '20', '--speed-limit', '1024', '--speed-time', '60',
        '--output', cached, url,
      ]);
    }
    if (sha256(cached) !== expected) throw new Error(`Checksum mismatch for ${project}`);
    const delivered = path.join(sourceDir, path.basename(cached));
    fs.copyFileSync(cached, delivered);
    const extracted = path.join(temp, `extract-${safeName(project)}`);
    fs.mkdirSync(extracted);
    run('tar', ['-xf', cached, '-C', extracted]);
    collectNotices(extracted, project);
  }

  const libjxlVersion = variables.LIBJXL_VERSION;
  const libplaceboVersion = variables.LIBPLACEBO_VERSION;
  if (!libjxlVersion || !libplaceboVersion) throw new Error('Missing git source versions');
  const additionalSums = [
    downloadPinnedSource('LIBJXL', `https://codeload.github.com/libjxl/libjxl/tar.gz/refs/tags/v${libjxlVersion}`),
    downloadPinnedSource('LIBPLACEBO', `https://code.videolan.org/videolan/libplacebo/-/archive/v${libplaceboVersion}/libplacebo-v${libplaceboVersion}.tar.gz`),
    // Exact submodule commits used by libplacebo v7.360.1 for its enabled
    // OpenGL build. Vulkan-Headers and demo-only Nuklear are disabled by IINA.
    downloadPinnedSource('LIBPLACEBO_GLAD', 'https://codeload.github.com/Dav1dde/glad/tar.gz/73db193f853e2ee079bf3ca8a64aa2eaf6459043'),
    downloadPinnedSource('LIBPLACEBO_JINJA', 'https://codeload.github.com/pallets/jinja/tar.gz/15206881c006c79667fe5154fe80c01c65410679'),
    downloadPinnedSource('LIBPLACEBO_MARKUPSAFE', 'https://codeload.github.com/pallets/markupsafe/tar.gz/297fc8e356e6836a62087949245d09a28e9f1b13'),
    downloadPinnedSource('LIBPLACEBO_FAST_FLOAT', 'https://codeload.github.com/fastfloat/fast_float/tar.gz/97b54ca9e75f5303507699d27c6b4f4efe4641a1'),
    // Exact libjxl v0.11.2 submodule revisions. Testdata, googletest and
    // SKCMS are excluded because IINA's production flags disable them.
    downloadPinnedSource('LIBJXL_BROTLI', 'https://codeload.github.com/google/brotli/tar.gz/36533a866ed1ca4b75cf049f4521e4ec5fe24727'),
    downloadPinnedSource('LIBJXL_HIGHWAY', 'https://codeload.github.com/google/highway/tar.gz/457c891775a7397bdb0376bb1031e6e027af1c48'),
    downloadPinnedSource('LIBJXL_LCMS', 'https://codeload.github.com/mm2/Little-CMS/tar.gz/5176347635785e53ee5cee92328f76fda766ecc6'),
    downloadPinnedSource('LIBJXL_LIBJPEG_TURBO', 'https://codeload.github.com/libjpeg-turbo/libjpeg-turbo/tar.gz/8ecba3647edb6dd940463fedf38ca33a8e2a73d1'),
    downloadPinnedSource('LIBJXL_LIBPNG', 'https://codeload.github.com/glennrp/libpng/tar.gz/872555f4ba910252783af1507f9e7fe1653be252'),
    downloadPinnedSource('LIBJXL_SJPEG', 'https://codeload.github.com/webmproject/sjpeg/tar.gz/94e0df6d0f8b44228de5be0ff35efb9f946a13c9'),
    downloadPinnedSource('LIBJXL_ZLIB', 'https://codeload.github.com/madler/zlib/tar.gz/51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf'),
  ];
  fs.writeFileSync(path.join(sourceDir, 'ADDITIONAL-SOURCE-SHA256SUMS.txt'), `${additionalSums.join('\n')}\n`);

  fs.copyFileSync(path.join(checkout, 'versions.env'), path.join(sourceDir, 'IINA-dependency-versions.env'));
  console.log(`Collected ${fs.readdirSync(sourceDir).length} source artifacts and ${fs.readdirSync(licenseDir).length} notice groups`);
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
