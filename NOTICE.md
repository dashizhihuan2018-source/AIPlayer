# Attribution and modifications

This is an unofficial macOS desktop adaptation of LibreTV, not an official LibreSpark native release.

- Upstream: https://github.com/LibreSpark/LibreTV
- Upstream version: 2.16.12
- Snapshot commit: a24ad336a3f7c8a16ca93d1f1198e08ac6b7e943
- Upstream copyright and license notices are preserved in `upstream/`.
- LibreTV and this derivative are provided under AGPL-3.0-or-later; see `LICENSE`.
- Desktop additions and modifications: Copyright (c) 2026 Nankong, AGPL-3.0-or-later.

Desktop changes (2026-10-15): native AppKit/WKWebView application, bundled loopback-only Node server, local authentication and lifecycle controls, desktop packaging and tests, direct-link playback/history/resume fixes, MP4 loading/cache/download guards, accurate local privacy copy, standalone tracing boundary, memory-only server cache to preserve bundle signatures, isolated DNS mocks in probe tests, and security updates to the dependency lock (Next.js 15.5.27, PostCSS 8.5.30, sharp 0.35.5, source-map-js 1.2.2).

The product display name is now 万能AI播放器. Existing LibreTV storage identities are retained for compatibility. The desktop preset list restores 22 public API endpoints from official historical commit `0d991bcc23d8e978bab2af13bb130ba3352642d4`; see `docs/SOURCES.md`. No proprietary OmniPlayer code, artwork or extracted binary resources are included, and no AI service is integrated in this build.

Node.js is separately licensed; its upstream license is included by the build script. JavaScript dependency licenses remain with their packages in the standalone application. Apple and Blender test videos, if referenced, are external test resources and are not bundled or relicensed by this project.

No third-party media files, user history, passwords, API keys, or private diagnostic material are included in this public source distribution. The listed third-party APIs are external services; their availability and content licensing are not guaranteed by this project. Use only sources and content you are authorized to access.
