// Run the upstream standalone server; never outlive the native app that owns us.
const parent = process.ppid;
if (parent <= 1) process.exit(1);
setInterval(() => {
  try {
    if (process.ppid !== parent) process.exit(0);
    process.kill(parent, 0);
  } catch { process.exit(0); }
}, 1500).unref();
require('./server/server.js');
