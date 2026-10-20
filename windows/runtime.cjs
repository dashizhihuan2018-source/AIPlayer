const fs = require("node:fs/promises"),
  path = require("node:path"),
  crypto = require("node:crypto");
const { spawn } = require("node:child_process");
const extractor = {
  url: "https://github.com/ip7z/7zip/releases/download/26.04/7zr.exe",
  sha256: "256feca8e274e5da655e2a284fabafd9f554365eb164862089dacd4e8276d282",
  source: "https://github.com/ip7z/7zip/releases/tag/26.04",
};
const releases = [
  [
    "mpv",
    "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20261020/mpv-x86_64-20261020-git-6a262d11f6.7z",
    "cbeda25235a24e9145f6ab3e784052e437e6e5aac306b682afd2bbf0070ddea8",
    "mpv.exe",
  ],
  [
    "ffmpeg",
    "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20261020/ffmpeg-x86_64-git-38ac3a923.7z",
    "a92d38a7d9d038db29eadc4a641821c0e5b85fa438aed28bb627458b3c3b1091",
    "ffmpeg.exe",
  ],
];
async function run(exe, args, options = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn(exe, args, {
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
      ...options,
    });
    const timer = setTimeout(() => {
      p.kill();
      reject(Error(path.basename(exe) + " 执行超时"));
    }, 300000);
    let output = "";
    const collect = (b) => {
      if (output.length < 100000) output += b.toString();
    };
    p.stdout?.on("data", collect);
    p.stderr?.on("data", collect);
    p.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
    p.on("close", (code) => {
      clearTimeout(timer);
      code === 0
        ? resolve(output)
        : reject(
            Error(
              path.basename(exe) +
                " 执行失败：" +
                code +
                " " +
                output.slice(-1500),
            ),
          );
    });
  });
}
async function find(root, name) {
  for (const e of await fs.readdir(root, { withFileTypes: true })) {
    if (e.isSymbolicLink()) continue;
    const p = path.join(root, e.name);
    if (e.isFile() && e.name === name) return p;
    if (e.isDirectory()) {
      const f = await find(p, name);
      if (f) return f;
    }
  }
  return null;
}
async function downloadVerified(url, sha256) {
  const response = await fetch(url, { signal: AbortSignal.timeout(180000) });
  if (!response.ok) throw Error("固定版本运行时下载失败");
  const bytes = Buffer.from(await response.arrayBuffer());
  if (
    bytes.length > 100 * 1024 * 1024 ||
    crypto.createHash("sha256").update(bytes).digest("hex") !== sha256
  )
    throw Error("运行时校验失败，拒绝运行");
  return bytes;
}
async function sharedLoader(binaries, directory) {
  // Reuse the audited loader already included in Electron 44.9.0 Windows x64.
  // No GPU driver installation or global PATH/system-directory mutation.
  const source = path.join(directory, "vulkan-1.dll");
  const data = await fs.readFile(source);
  const expected =
    "03120814ccb06e0fa9141cfa7c2ec906984f32ef56f8caf50e56e97a7a3225fa";
  if (crypto.createHash("sha256").update(data).digest("hex") !== expected)
    throw Error("随包Vulkan加载库与固定Electron版本不符，拒绝运行引擎");
  for (const binary of Object.values(binaries)) {
    const destination = path.join(path.dirname(binary), "vulkan-1.dll");
    const existing = await fs.readFile(destination).catch(() => null);
    if (
      !existing ||
      crypto.createHash("sha256").update(existing).digest("hex") !== expected
    )
      await fs.writeFile(destination, data);
  }
}
async function ensure(root, consent, options = {}) {
  if (process.platform !== "win32") {
    if (!process.env.MPV_BINARY || !process.env.FFMPEG_BINARY)
      throw Error("测试需要显式提供本机 MPV_BINARY/FFMPEG_BINARY");
    return { mpv: process.env.MPV_BINARY, ffmpeg: process.env.FFMPEG_BINARY };
  }
  const binaries = {};
  let missing = false;
  for (const [id, , , name] of releases) {
    binaries[id] = await find(path.join(root, id), name).catch(() => null);
    if (!binaries[id]) missing = true;
  }
  const loaderDirectory =
    options.loaderDirectory || path.dirname(process.execPath);
  if (!missing) {
    await sharedLoader(binaries, loaderDirectory);
    return binaries;
  }
  if (!(await consent()))
    throw Error("播放引擎尚未安装；可下次打开本地文件时安装");
  await fs.mkdir(root, { recursive: true });
  // Windows Server's built-in tar cannot decode the upstream archives' LZMA.
  // Direct user download of the pinned standalone 7zr, not an installer or a
  // system-wide modification. Never executes an unverified cached downloader.
  const sevenzip = path.join(root, "7zr-26.04.exe");
  let cached = await fs.readFile(sevenzip).catch(() => null);
  if (
    !cached ||
    crypto.createHash("sha256").update(cached).digest("hex") !==
      extractor.sha256
  ) {
    cached = await downloadVerified(extractor.url, extractor.sha256);
    await fs.writeFile(sevenzip, cached);
  }
  await fs.writeFile(
    path.join(root, "7ZIP-PROVENANCE.json"),
    JSON.stringify(
      {
        ...extractor,
        license: "GNU LGPL; see upstream DOC/License.txt",
        licenseURL: "https://github.com/ip7z/7zip/blob/26.04/DOC/License.txt",
        redistribution:
          "Direct user download; not bundled in AIPlayer installer",
      },
      null,
      2,
    ),
  );
  for (const [id, url, sha, name] of releases) {
    if (binaries[id]) continue;
    const temp = path.join(root, id + "-" + crypto.randomUUID());
    await fs.mkdir(temp);
    try {
      const bytes = await downloadVerified(url, sha);
      const archive = path.join(temp, "runtime.7z");
      await fs.writeFile(archive, bytes);
      await run(sevenzip, ["x", archive, "-o" + temp, "-y", "-bso0", "-bsp0"]);
      await fs.unlink(archive);
      if (!(await find(temp, name))) throw Error("引擎缺少可执行文件");
      await fs.writeFile(
        path.join(temp, "DOWNLOAD-PROVENANCE.json"),
        JSON.stringify(
          {
            url,
            sha256: sha,
            sourceBuild: "https://github.com/shinchiro/mpv-winbuild-cmake",
            redistribution:
              "Direct user download; not bundled in AIPlayer installer",
          },
          null,
          2,
        ),
      );
      await fs.rename(temp, path.join(root, id));
      binaries[id] = await find(path.join(root, id), name);
    } catch (e) {
      await fs.rm(temp, { recursive: true, force: true });
      throw e;
    }
  }
  await sharedLoader(binaries, loaderDirectory);
  return binaries;
}
module.exports = { run, ensure, releases, extractor };
