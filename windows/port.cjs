"use strict";
const fs = require("node:fs/promises"),
  path = require("node:path"),
  net = require("node:net");
async function probe(port) {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen({ host: "127.0.0.1", port, exclusive: true }, () => {
      const value = server.address().port;
      server.close((error) => (error ? reject(error) : resolve(value)));
    });
  });
}
async function persistentPort(folder) {
  await fs.mkdir(folder, { recursive: true });
  const file = path.join(folder, "server-port.json");
  let port;
  try {
    port = JSON.parse(await fs.readFile(file, "utf8")).port;
  } catch (error) {
    if (error.code !== "ENOENT")
      throw Error("本机端口配置无法读取，已保留原配置：" + error.message);
  }
  if (port !== undefined) {
    if (!Number.isInteger(port) || port < 1024 || port > 65535)
      throw Error("本机端口配置无效；不自动更换网址，以免丢失浏览器设置");
    try {
      return await probe(port);
    } catch (error) {
      throw Error(
        "本机端口 " +
          port +
          " 正被占用，请关闭冲突程序后重试。未更改偏好数据。" +
          error.code,
      );
    }
  }
  port = await probe(0);
  await fs.writeFile(file, JSON.stringify({ port }), {
    flag: "wx",
    mode: 0o600,
  });
  return port;
}
module.exports = { persistentPort };
