"use strict";
const {
  app,
  BrowserWindow,
  Menu,
  dialog,
  ipcMain,
  session,
  shell,
} = require("electron");
const fs = require("node:fs/promises"),
  path = require("node:path"),
  os = require("node:os"),
  net = require("node:net"),
  crypto = require("node:crypto");
const { spawn } = require("node:child_process");
const { MPV } = require("./mpv.cjs"),
  policy = require("./policy.cjs"),
  runtime = require("./runtime.cjs");
const smoke = process.argv.includes("--smoke-test");
if (smoke)
  app.setPath(
    "userData",
    path.join(os.tmpdir(), "AIPlayer-smoke-" + process.pid),
  );
let win,
  video,
  server,
  base,
  engine,
  binaries,
  rect = null,
  media = null,
  recording = null,
  gif = null,
  pip = false;
const localFiles = new Map();
let serial = Promise.resolve();
function cleanup() {
  app.isQuitting = true;
  if (gif) clearInterval(gif.timer);
  engine?.stop();
  server?.kill();
}
function exit(code) {
  cleanup();
  app.exit(code);
}
const output = (kind) =>
  path.join(
    app.getPath(kind === "Clips" ? "videos" : "pictures"),
    "AIPlayer",
    kind,
  );
async function destination(kind, ext) {
  const folder = output(kind);
  await fs.mkdir(folder, { recursive: true });
  return path.join(
    folder,
    "AIPlayer-" +
      new Date().toISOString().replace(/[:.]/g, "-") +
      "-" +
      crypto.randomUUID().slice(0, 6) +
      ext,
  );
}
function emit(detail) {
  if (win && !win.isDestroyed()) win.webContents.send("native-event", detail);
}
function state() {
  return {
    ...(engine?.state() || {
      available: false,
      engine: "mpv 未安装",
      paused: true,
      time: 0,
      duration: 0,
      volume: 80,
      speed: 1,
      muted: false,
      title: "",
      tracks: [],
      chapters: [],
      width: 0,
      height: 0,
      subtitleDelay: 0,
      audioDelay: 0,
    }),
    recording: !!recording,
    exporting: false,
    gifCapturing: !!gif,
    gifExporting: false,
    gifElapsed: gif ? (Date.now() - gif.start) / 1000 : 0,
  };
}
function position() {
  if (!video || video.isDestroyed() || !rect) return;
  if (!rect.visible || win.isMinimized()) {
    video.hide();
    return;
  }
  const bounds = win.getContentBounds();
  const h = Math.min(rect.height, Math.max(0, bounds.height - rect.y)),
    w = Math.min(rect.width, Math.max(0, bounds.width - rect.x));
  if (w < 2 || h < 2) {
    video.hide();
    return;
  }
  video.setBounds({
    x: Math.round(bounds.x + rect.x),
    y: Math.round(bounds.y + rect.y),
    width: Math.round(w),
    height: Math.round(h),
  });
  video.showInactive();
}
async function initEngine() {
  if (engine && !engine.dead) return;
  binaries = await runtime.ensure(
    path.join(app.getPath("userData"), "runtime-v20261020"),
    async () =>
      smoke ||
      (
        await dialog.showMessageBox(win, {
          type: "question",
          message: "安装 Windows 播放引擎？",
          detail:
            "从 mpv 社区构建仓库下载固定版本 mpv/FFmpeg（约 62 MB），核验 SHA-256 后解压到本机应用数据目录。首次需联网，之后可离线播放本地文件。第三方代码保留原许可，未打包进本安装器。",
          buttons: ["取消", "下载并安装"],
          defaultId: 0,
          cancelId: 0,
        })
      ).response === 1,
  );
  video = new BrowserWindow({
    parent: win,
    width: 10,
    height: 10,
    frame: false,
    show: false,
    skipTaskbar: true,
    focusable: false,
    resizable: false,
    backgroundColor: "#000000",
    webPreferences: {
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  const h = video.getNativeWindowHandle(),
    wid =
      h.length === 8
        ? h.readBigUInt64LE().toString()
        : h.readUInt32LE().toString();
  engine = new MPV(binaries.mpv, wid);
  engine.on("engine-error", (e) =>
    emit({ event: "state", state: { ...state(), error: e.message } }),
  );
  engine.on("state", () => emit({ event: "state", state: state() }));
  engine.on("ended", (reason) => {
    if (reason === "eof")
      emit({ event: "state", state: { ...state(), ended: true } });
  });
  await engine.start();
  position();
}
async function files(paths) {
  const result = [];
  for (const f of paths) {
    const s = await fs.stat(f);
    if (!s.isFile()) continue;
    const id = crypto.randomUUID();
    localFiles.set(id, f);
    result.push({ id, name: path.basename(f), kind: "local" });
  }
  return result;
}
async function openFiles() {
  const p = await dialog.showOpenDialog(win, {
    properties: ["openFile", "multiSelections"],
    filters: [
      {
        name: "媒体",
        extensions: [
          "mp4",
          "mkv",
          "mov",
          "avi",
          "webm",
          "m4v",
          "mp3",
          "flac",
          "wav",
          "aac",
          "ogg",
        ],
      },
      { name: "所有文件", extensions: ["*"] },
    ],
  });
  return p.canceled ? [] : files(p.filePaths);
}
async function gifStart(args) {
  if (gif) throw Error("GIF 已在录制");
  await initEngine();
  const fps = policy.finite(args.fps, 1, 30),
    width = policy.finite(args.maximumWidth, 640, 3840);
  if (!Number.isInteger(fps) || ![640, 1280, 1920, 3840].includes(width))
    throw Error("无效 GIF 参数");
  if (!media || !state().duration) throw Error("请先播放媒体");
  const dir = await fs.mkdtemp(path.join(app.getPath("temp"), "aiplayer-gif-"));
  const g = (gif = {
    dir,
    start: Date.now(),
    fps,
    width,
    count: 0,
    bytes: 0,
    busy: false,
    ended: false,
  });
  const capture = async () => {
    if (g.ended) return;
    if (g.busy) return;
    g.busy = true;
    try {
      if (!state().paused) {
        const f = path.join(dir, String(g.count).padStart(6, "0") + ".png");
        await engine.call(["screenshot-to-file", f, "video"]);
        g.bytes += (await fs.stat(f)).size;
        g.count++;
      }
      if (
        g.bytes > 512 * 1024 * 1024 ||
        g.count >= 4500 ||
        Date.now() - g.start > 120000
      ) {
        g.ended = true;
        emit({
          event: "state",
          state: {
            ...state(),
            gifError: "达到预览版录制资源上限，请点击停止保存",
          },
        });
      }
    } catch (e) {
      g.ended = true;
      emit({ event: "state", state: { ...state(), gifError: e.message } });
    } finally {
      g.busy = false;
    }
  };
  g.timer = setInterval(capture, 1000 / fps);
  await capture();
  return { capturing: true };
}
async function gifStop(cancel = false) {
  const g = gif;
  if (!g) return { cancelled: true };
  clearInterval(g.timer);
  g.ended = true;
  while (g.busy) await new Promise((r) => setTimeout(r, 30));
  gif = null;
  try {
    if (cancel || g.count < 2) return { cancelled: true };
    const dest = await destination("GIF", ".gif");
    await runtime.run(binaries.ffmpeg, [
      "-v",
      "error",
      "-framerate",
      String(g.fps),
      "-i",
      path.join(g.dir, "%06d.png"),
      "-filter_complex",
      `scale=w='min(iw,${g.width})':h=-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse`,
      "-loop",
      "0",
      dest,
    ]);
    emit({
      event: "state",
      state: { ...state(), gifSavedName: path.basename(dest) },
    });
    return { saved: true, name: path.basename(dest) };
  } finally {
    await fs.rm(g.dir, { recursive: true, force: true });
  }
}
async function request(m) {
  if (
    !m ||
    typeof m.command !== "string" ||
    typeof m.id !== "string" ||
    m.id.length > 200
  )
    throw Error("无效原生请求");
  const a = m.args || {},
    cmd = m.command;
  if (cmd === "capabilities")
    return {
      available: !!engine && !engine.dead,
      engine: "mpv Windows",
      commands: [
        "pause",
        "seek",
        "volume",
        "mute",
        "speed",
        "audioTrack",
        "subtitleTrack",
        "subtitleDelay",
        "audioDelay",
        "aspect",
        "rotation",
        "brightness",
        "contrast",
        "saturation",
        "gamma",
        "hue",
        "abLoopA",
        "abLoopB",
        "loop",
        "deinterlace",
        "hwdec",
        "frameStep",
        "frameBackStep",
        "stop",
        "gifStart",
        "gifStop",
        "gifCancel",
        "openGifFolder",
        "capturePoster",
        "recordStart",
        "recordStop",
        "mediaReady",
        "mediaNotReady",
        "getWindowState",
      ],
      openFiles: true,
      importSubtitle: true,
      screenshot: true,
      fullscreen: true,
    };
  if (cmd === "getState") return state();
  if (cmd === "getWindowState")
    return { fullscreen: win.isFullScreen(), pictureInPicture: pip };
  if (cmd === "setVideoRect") {
    rect = policy.rectangle(a);
    position();
    return true;
  }
  if (cmd === "hideVideo" || cmd === "mediaNotReady") {
    if (video) video.hide();
    return true;
  }
  if (cmd === "mediaReady") {
    position();
    return true;
  }
  if (cmd === "openFiles") return openFiles();
  if (cmd === "fullscreen") {
    win.setFullScreen(!win.isFullScreen());
    setTimeout(position, 300);
    return { fullscreen: win.isFullScreen(), pictureInPicture: false };
  }
  if (cmd === "openGifFolder") {
    await fs.mkdir(output("GIF"), { recursive: true });
    await shell.openPath(output("GIF"));
    return true;
  }
  if (cmd === "load") {
    await gifStop(true);
    recording = null;
    await initEngine();
    let target;
    if (
      typeof a.id === "string" &&
      localFiles.has(a.id) &&
      a.url === undefined
    ) {
      target = localFiles.get(a.id);
    } else if (typeof a.url === "string" && a.id === undefined) {
      target = policy.mediaURL(a.url);
    } else throw Error("本地媒体授权不存在或 URL 无效");
    media = target;
    await engine.call(["loadfile", target, "replace"]);
    await engine.call(["set_property", "pause", false]);
    if (a.position !== undefined) {
      policy.finite(a.position, 0, 604800);
      await engine.call(["seek", a.position, "absolute"]);
    }
    position();
    return state();
  }
  if (cmd === "command") {
    await initEngine();
    if (recording && a.name === "seek")
      throw Error("片段录制时不能跳转，请先停止");
    await engine.call(policy.engineCommand(a.name, a.value));
    return state();
  }
  if (cmd === "importSubtitle") {
    await initEngine();
    const p = await dialog.showOpenDialog(win, {
      properties: ["openFile"],
      filters: [
        { name: "字幕", extensions: ["srt", "ass", "ssa", "vtt", "sub"] },
      ],
    });
    if (!p.canceled) await engine.call(["sub-add", p.filePaths[0], "select"]);
    return state();
  }
  if (cmd === "screenshot") {
    await initEngine();
    const dest = await destination("Screenshots", ".png");
    await engine.call(["screenshot-to-file", dest, "video"]);
    return { saved: true, name: path.basename(dest) };
  }
  if (cmd === "gifStart") return gifStart(a);
  if (cmd === "gifStop") return gifStop();
  if (cmd === "gifCancel") return gifStop(true);
  if (cmd === "capturePoster") {
    await initEngine();
    if (!media || !localFilesHasPath(media) || !state().duration)
      throw Error("时间线海报仅支持已授权的本地媒体");
    const dest = await destination("Posters", ".jpg");
    await runtime.run(binaries.ffmpeg, [
      "-v",
      "error",
      "-i",
      media,
      "-vf",
      `fps=5/${state().duration},scale=320:-2,tile=5x1`,
      "-frames:v",
      "1",
      dest,
    ]);
    return { saved: true, name: path.basename(dest) };
  }
  if (cmd === "recordStart") {
    if (!localFilesHasPath(media))
      throw Error("片段保存仅支持已授权的本地文件");
    recording = { source: media, start: state().time };
    return { recording: true };
  }
  if (cmd === "recordStop") {
    const r = recording;
    recording = null;
    if (!r || media !== r.source) throw Error("没有有效的片段起点");
    const duration = state().time - r.start;
    if (duration <= 0.1 || duration > 300)
      throw Error("片段长度必须为 0.1–300 秒");
    const dest = await destination("Clips", ".mp4");
    await runtime.run(binaries.ffmpeg, [
      "-v",
      "error",
      "-ss",
      String(r.start),
      "-i",
      r.source,
      "-t",
      String(duration),
      "-c:v",
      "libx264",
      "-preset",
      "fast",
      "-crf",
      "20",
      "-c:a",
      "aac",
      dest,
    ]);
    return { saved: true, name: path.basename(dest) };
  }
  throw Error("此功能尚未完成 Windows 适配");
}
function localFilesHasPath(file) {
  return [...localFiles.values()].includes(file);
}
async function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.on("error", reject);
    s.listen(0, "127.0.0.1", () => {
      const p = s.address().port;
      s.close(() => resolve(p));
    });
  });
}
async function startServer() {
  const root = app.isPackaged
    ? path.join(process.resourcesPath, "server")
    : path.join(__dirname, "server");
  const port = await freePort(),
    password = policy.token();
  base = "http://127.0.0.1:" + port;
  const sources = JSON.parse(
    await fs.readFile(path.join(__dirname, "sources.json"), "utf8"),
  );
  const proxySecret = policy.token();
  let serverDiagnostic = "";
  server = spawn(process.execPath, [path.join(root, "server.js")], {
    cwd: root,
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      ELECTRON_RUN_AS_NODE: "1",
      NODE_ENV: "production",
      PORT: String(port),
      HOSTNAME: "127.0.0.1",
      PASSWORD: password,
      PROXY_SECRET: proxySecret,
      COOKIE_SECURE: "false",
      NEXT_TELEMETRY_DISABLED: "1",
      DEFAULT_RECOMMEND_SOURCE: "douban",
      DEFAULT_SOURCES: JSON.stringify(sources),
    },
  });
  let failed;
  const log = (b) => {
    serverDiagnostic = (serverDiagnostic + b.toString())
      .slice(-12000)
      .replaceAll(password, "[redacted]")
      .replaceAll(proxySecret, "[redacted]");
  };
  server.stdout.on("data", log);
  server.stderr.on("data", log);
  server.on("error", (e) => (failed = e));
  server.on("exit", (code) => {
    if (!app.isQuitting)
      failed = Error("本机服务已退出：" + code + "\n" + serverDiagnostic);
  });
  const until = Date.now() + 60000;
  while (Date.now() < until) {
    if (failed) throw failed;
    try {
      const r = await session.defaultSession.fetch(base + "/api/status", {
        signal: AbortSignal.timeout(1000),
      });
      if (r.ok) {
        const auth = await session.defaultSession.fetch(base + "/api/auth", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ password }),
        });
        if (!auth.ok) throw Error("本机认证失败");
        return;
      }
    } catch {}
    await new Promise((r) => setTimeout(r, 250));
  }
  throw Error("本机服务启动超时");
}
app
  .whenReady()
  .then(async () => {
    if (!smoke && !app.requestSingleInstanceLock()) {
      app.quit();
      return;
    }
    win = new BrowserWindow({
      width: 1240,
      height: 820,
      minWidth: 850,
      minHeight: 600,
      title: "万能AI播放器",
      icon: path.join(
        app.isPackaged ? process.resourcesPath : __dirname,
        "server/public/icons/icon-512.png",
      ),
      show: !smoke,
      backgroundColor: "#090d18",
      webPreferences: {
        preload: path.join(__dirname, "preload.cjs"),
        sandbox: true,
        contextIsolation: true,
        nodeIntegration: false,
      },
    });
    await win.loadURL(
      "data:text/html;charset=utf-8," +
        encodeURIComponent(
          '<!doctype html><meta charset="utf-8"><title>万能AI播放器 · 正在启动</title><body style="margin:60px;background:#090d18;color:#e5edff;font:18px system-ui"><h1>万能AI播放器</h1><p>正在启动本机服务。首次安装引擎需确认并联网下载约62MB，请等待校验完成。</p><p>取消下载后仍可使用网页搜索；不会上传本地媒体。</p>',
        ),
    );
    ipcMain.handle("native", (event, m) => {
      if (
        event.senderFrame !== win.webContents.mainFrame ||
        new URL(event.senderFrame.url).origin !== base
      )
        throw Error("Untrusted frame");
      const result = serial.then(() => request(m));
      serial = result.catch(() => {});
      return result;
    });
    win.webContents.setWindowOpenHandler(({ url }) => {
      try {
        policy.mediaURL(url);
        shell.openExternal(url);
      } catch {}
      return { action: "deny" };
    });
    win.webContents.on("will-navigate", (e, url) => {
      if (!base || new URL(url).origin !== base) e.preventDefault();
    });
    for (const name of [
      "move",
      "resize",
      "restore",
      "enter-full-screen",
      "leave-full-screen",
    ])
      win.on(name, () => {
        position();
        if (name.includes("full-screen"))
          emit({
            event: "windowState",
            fullscreen: win.isFullScreen(),
            pictureInPicture: false,
            transitioning: false,
          });
      });
    win.on("minimize", () => video?.hide());
    Menu.setApplicationMenu(
      Menu.buildFromTemplate([
        {
          label: "文件",
          submenu: [
            {
              label: "打开媒体…",
              accelerator: "CmdOrCtrl+O",
              click: async () => {
                try {
                  if (!engine || engine.dead) {
                    await initEngine();
                    await win.reload();
                    return;
                  }
                  const items = await openFiles();
                  if (items.length) emit({ event: "openMedia", items });
                } catch (e) {
                  dialog.showErrorBox("打开媒体失败", e.message);
                }
              },
            },
            {
              label: "打开 GIF 文件夹",
              click: () => shell.openPath(output("GIF")),
            },
            { type: "separator" },
            { role: "quit" },
          ],
        },
        {
          label: "编辑",
          submenu: [
            { role: "undo" },
            { role: "redo" },
            { role: "cut" },
            { role: "copy" },
            { role: "paste" },
            { role: "selectAll" },
          ],
        },
        {
          label: "视图",
          submenu: [{ role: "togglefullscreen" }, { role: "reload" }],
        },
      ]),
    );
    await startServer();
    try {
      await initEngine();
    } catch (e) {
      if (smoke) throw e;
      dialog.showErrorBox(
        "播放引擎尚未就绪",
        e.message + "。当前可使用网页搜索；稍后从「文件 → 打开媒体」重试安装。",
      );
    }
    await win.loadURL(base);
    if (smoke) {
      try {
        const fixture = path.join(
          app.getPath("temp"),
          "aiplayer-synthetic-" + process.pid + ".mp4",
        );
        await runtime.run(binaries.ffmpeg, [
          "-v",
          "error",
          "-f",
          "lavfi",
          "-i",
          "testsrc2=size=320x180:rate=25",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:sample_rate=44100",
          "-t",
          "8",
          "-c:v",
          "libx264",
          "-pix_fmt",
          "yuv420p",
          "-c:a",
          "aac",
          "-y",
          fixture,
        ]);
        const ids = await files([fixture]);
        await request({
          id: "smoke",
          command: "load",
          args: { id: ids[0].id },
        });
        const deadline = Date.now() + 15000;
        while (
          Date.now() < deadline &&
          (!state().duration || state().width !== 320 || state().time <= 0)
        )
          await new Promise((r) => setTimeout(r, 100));
        const s = state();
        if (!s.duration || s.width !== 320 || s.time <= 0)
          throw Error("真实解码/时间推进未通过：" + JSON.stringify(s));
        const screenshot = await destination("Screenshots", ".png");
        await engine.call(["screenshot-to-file", screenshot, "video"]);
        const header = (await fs.readFile(screenshot))
          .subarray(0, 8)
          .toString("hex");
        if (header !== "89504e470d0a1a0a") throw Error("截图格式错误");
        const result = await win.webContents.executeJavaScript(
          `new Promise((resolve,reject)=>{const end=Date.now()+15000;const check=()=>{if(document.body.innerText.includes('全网资源')&&window.webkit?.messageHandlers?.desktop){const id='ci-bridge';const timer=setTimeout(()=>reject(Error('Bridge reply timeout')),5000);window.addEventListener('aiplayer:native',function done(e){if(e.detail?.id===id){window.removeEventListener('aiplayer:native',done);clearTimeout(timer);resolve({title:document.title,text:document.body.innerText.slice(0,1000),bridge:!!e.detail.result?.available});}});window.webkit.messageHandlers.desktop.postMessage({id,command:'capabilities',args:{}});}else if(Date.now()>end)reject(Error('Original UI not ready'));else setTimeout(check,100);};check();})`,
        );
        if (!result.bridge) throw Error("原始首页/跨隔离域原生桥未就绪");
        const dir = process.env.SMOKE_OUTPUT || app.getPath("temp");
        await fs.mkdir(dir, { recursive: true });
        await fs.writeFile(
          path.join(dir, "aiplayer-smoke.json"),
          JSON.stringify(
            {
              status: "automated-smoke-only",
              state: s,
              result,
              platform: process.platform,
              arch: process.arch,
            },
            null,
            2,
          ),
        );
        await fs.writeFile(
          path.join(dir, "aiplayer-smoke.png"),
          (await win.webContents.capturePage()).toPNG(),
        );
        await fs.copyFile(
          screenshot,
          path.join(dir, "aiplayer-video-frame.png"),
        );
        exit(0);
      } catch (e) {
        console.error(e);
        exit(1);
      }
    }
  })
  .catch((e) => {
    if (smoke) console.error(e);
    else dialog.showErrorBox("万能AI播放器启动失败", e.message);
    exit(1);
  });
app.on("before-quit", cleanup);
app.on("will-quit", cleanup);
app.on("window-all-closed", () => app.quit());
app.on("second-instance", () => {
  if (win) {
    if (win.isMinimized()) win.restore();
    win.show();
    win.focus();
  }
});
