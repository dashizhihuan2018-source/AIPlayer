# Native playback dependencies

The desktop playback engine uses the independently licensed arm64 slice of
`libmpv.2.dylib` distributed by the official IINA v1.5.0 release, whose published
build uses mpv 0.41.0 and FFmpeg 9.0.1. Public mpv 0.41.0 source headers are pinned
separately by checksum. No binaries, source, or resources from OmniPlayer are used.

mpv is distributed under GPL-2.0-or-later and LGPL-2.1-or-later terms depending on
the configured build. The containing application is AGPL-3.0-or-later. The build
copies mpv/IINA license texts, IINA's dependency credits, and the dynamically required libraries
into the application bundle, rebases their load commands, and signs each nested
library before signing the outer application.

Pinned inputs: IINA v1.5.0 DMG SHA-256
`8fad50479b10e09645053457cec46bd53d054ced2242cfe68f74586735a20dc7`;
mpv v0.41.0 source archive SHA-256
`ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209`.
