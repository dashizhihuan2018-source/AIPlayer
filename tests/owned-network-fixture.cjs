// Local-only controlled HLS fixture: later segments take longer than the old
// four-second poster deadline. Never proxies or logs real user media.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const root = fs.realpathSync(process.argv[2]);
let offline = false;
http.createServer((req, res) => {
  const pathname = new URL(req.url, 'http://localhost').pathname;
  if (pathname === '/offline' || pathname === '/online') {
    offline = pathname === '/offline'; res.end(offline ? 'offline' : 'online'); return;
  }
  const file = path.resolve(root, '.' + pathname);
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
  const send = () => {
    if (res.destroyed) return;
    if (offline) { res.writeHead(503); res.end(); return; }
    res.writeHead(200, { 'Content-Length': fs.statSync(file).size, 'Content-Type': file.endsWith('.m3u8') ? 'application/vnd.apple.mpegurl' : 'video/mp2t' });
    if (req.method === 'HEAD') res.end(); else fs.createReadStream(file).pipe(res);
  };
  if (file.endsWith('.ts') && !file.endsWith('index0.ts')) setTimeout(send, 5500); else send();
}).listen(19785, '127.0.0.1', () => console.log('Owned HLS fixture ready on 127.0.0.1:19785'));
