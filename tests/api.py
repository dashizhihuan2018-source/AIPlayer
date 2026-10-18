"""Local installed-app API checks. Never print the password or session cookie."""
import http.cookiejar
import json
import urllib.request
import urllib.error
from pathlib import Path

BASE = "http://127.0.0.1:18784"
jar = http.cookiejar.CookieJar()
client = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(jar))


def call(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, headers={"Content-Type": "application/json"})
    try:
        with client.open(req, timeout=20) as res:
            return res.status, json.load(res)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


status, body = call("/api/status")
assert status == 200 and body["version"] == "2.16.12" and body["verified"] is False
assert call("/api/search", {"wd": "test", "sources": []})[0] == 401
assert call("/api/auth", {"password": "intentionally-wrong-local-test"})[0] == 401
password = (Path.home() / "Library/Application Support/LibreTV Desktop/local-password").read_text().strip()
assert call("/api/auth", {"password": password}) == (200, {"success": True})
assert call("/api/status")[1]["verified"] is True
assert call("/api/search", {"wd": "test", "sources": []})[0] == 400
status, body = call("/api/search", {"wd": "test", "sources": [{"key": "blocked", "name": "SSRF regression", "url": "http://127.0.0.1:9"}]})
assert status == 200 and not body["list"] and body["failures"]
assert call("/api/detail?id=invalid%20id&source=%7B%7D")[0] == 400
print("PASS: 8 local API checks (version, auth, missing-source error, SSRF, invalid detail)")
