"use strict";
const { spawn } = require("node:child_process"),
  net = require("node:net"),
  crypto = require("node:crypto");
const { EventEmitter } = require("node:events");
class MPV extends EventEmitter {
  constructor(binary, wid) {
    super();
    this.binary = binary;
    this.wid = wid;
    this.sequence = 0;
    this.pending = new Map();
    this.values = {};
    this.dead = false;
  }
  async start() {
    this.pipe =
      process.platform === "win32"
        ? "\\\\.\\pipe\\aiplayer-" + crypto.randomUUID()
        : require("node:path").join(
            require("node:os").tmpdir(),
            "aiplayer-" + crypto.randomUUID() + ".sock",
          );
    const args = [
      "--idle=yes",
      "--no-config",
      "--no-terminal",
      "--osc=no",
      "--input-default-bindings=no",
      "--input-vo-keyboard=no",
      "--input-ipc-server=" + this.pipe,
      "--hwdec=auto-safe",
      "--screenshot-format=png",
    ];
    if (this.wid) args.push("--wid=" + this.wid);
    this.process = spawn(this.binary, args, {
      windowsHide: true,
      stdio: ["ignore", "ignore", "pipe"],
    });
    let spawnError;
    this.process.on("error", (e) => {
      spawnError = e;
      this.fail(e);
    });
    this.process.on("exit", (code) => {
      this.dead = true;
      this.fail(Error("播放引擎已退出：" + code));
    });
    this.process.stderr.on("data", () => {});
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      if (spawnError) throw spawnError;
      if (this.dead) throw Error("mpv 启动失败");
      try {
        this.socket = await new Promise((resolve, reject) => {
          const s = net.connect(this.pipe, () => {
            s.removeListener("error", reject);
            resolve(s);
          });
          s.once("error", (e) => {
            s.destroy();
            reject(e);
          });
        });
        break;
      } catch {
        await new Promise((r) => setTimeout(r, 150));
      }
    }
    if (!this.socket) {
      this.stop();
      throw Error("播放引擎 IPC 超时");
    }
    let buffer = "";
    this.socket.setEncoding("utf8");
    this.socket.on("data", (part) => {
      buffer += part;
      if (buffer.length > 8 * 1024 * 1024) {
        this.stop();
        return;
      }
      let at;
      while ((at = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, at);
        buffer = buffer.slice(at + 1);
        try {
          const m = JSON.parse(line);
          if (m.request_id && this.pending.has(m.request_id)) {
            const p = this.pending.get(m.request_id);
            this.pending.delete(m.request_id);
            clearTimeout(p.timer);
            m.error === "success"
              ? p.resolve(m.data)
              : p.reject(Error(m.error));
          }
          if (m.event === "property-change") {
            this.values[m.name] = m.data;
            this.emit("state");
          }
          if (m.event === "end-file") this.emit("ended", m.reason);
        } catch {}
      }
    });
    this.socket.on("error", (e) => this.fail(e));
    this.socket.on("close", () => this.fail(Error("mpv IPC 已关闭")));
    const names = [
      "pause",
      "time-pos",
      "duration",
      "volume",
      "speed",
      "mute",
      "media-title",
      "track-list",
      "chapter-list",
      "width",
      "height",
      "sub-delay",
      "audio-delay",
      "mpv-version",
    ];
    for (let i = 0; i < names.length; i++)
      await this.call(["observe_property", i + 1, names[i]]);
  }
  call(command) {
    if (!this.socket || this.dead)
      return Promise.reject(Error("播放引擎未连接"));
    const request_id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(request_id);
        reject(Error("播放命令超时"));
      }, 10000);
      this.pending.set(request_id, { resolve, reject, timer });
      this.socket.write(JSON.stringify({ command, request_id }) + "\n", (e) => {
        if (e) {
          clearTimeout(timer);
          this.pending.delete(request_id);
          reject(e);
        }
      });
    });
  }
  fail(error) {
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.reject(error);
    }
    this.pending.clear();
    this.emit("engine-error", error);
  }
  stop() {
    this.socket?.destroy();
    this.process?.kill();
    this.dead = true;
  }
  state() {
    const v = this.values,
      n = (key, f = 0) => (Number.isFinite(v[key]) ? v[key] : f);
    return {
      available: !this.dead && !!this.socket,
      engine: String(v["mpv-version"] || "mpv"),
      paused: v.pause !== false,
      time: n("time-pos"),
      duration: n("duration"),
      volume: n("volume", 80),
      speed: n("speed", 1),
      muted: !!v.mute,
      title: String(v["media-title"] || ""),
      tracks: (v["track-list"] || [])
        .filter((x) => ["audio", "sub", "video"].includes(x.type))
        .map((x) => ({
          id: x.id,
          type: x.type,
          selected: !!x.selected,
          ...(x.title ? { title: x.title } : {}),
          ...(x.lang ? { lang: x.lang } : {}),
        })),
      chapters: (v["chapter-list"] || []).map((x) => ({
        time: x.time,
        title: x.title || "",
      })),
      width: n("width"),
      height: n("height"),
      subtitleDelay: n("sub-delay"),
      audioDelay: n("audio-delay"),
    };
  }
}
module.exports = { MPV };
