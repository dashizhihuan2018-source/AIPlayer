"""Installed default-source/search/detail checks, separate from actual playback QA.

Uses the local app's existing authentication only; never prints secrets or URLs
returned by providers. Network availability is point-in-time, not a guarantee.
"""
import http.cookiejar
import json
import urllib.parse
import urllib.request
from pathlib import Path

BASE = "http://127.0.0.1:18784"
client = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
)


def call(path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(
        BASE + path, data=data, headers={"Content-Type": "application/json"}
    )
    with client.open(request, timeout=35) as response:
        assert response.status == 200
        return json.load(response)


password = (Path.home() / "Library/Application Support/LibreTV Desktop/local-password").read_text().strip()
assert call("/api/auth", {"password": password})["success"] is True
sources = call("/api/status")["defaultSources"]
assert len(sources) == 22
assert len({source["url"] for source in sources}) == 22
assert all(source.get("isAdult") is False for source in sources)
assert all("example.com" not in source["url"] for source in sources)
search = call("/api/search", {"wd": "大闹天宫", "sources": sources, "filterAdult": True})
assert search["list"], "No actual catalogue result returned"
source = next(source for source in sources if source["name"] == "非凡影视")
item = next(item for item in search["list"] if item["sourceKey"] == source["key"])
detail = call("/api/detail?" + urllib.parse.urlencode({"id": item["vodId"], "source": json.dumps(source)}))
assert detail["episodes"]
assert all(episode.split("$", 1)[-1].startswith(("http://", "https://")) for episode in detail["episodes"])
print(f"PASS: 22 unique automatic sources; actual search {len(search['list'])} results, "
      f"{len(search.get('failures', []))} source failures; 非凡影视 detail {len(detail['episodes'])} episode(s). "
      "This checks API data, not media decoding.")
