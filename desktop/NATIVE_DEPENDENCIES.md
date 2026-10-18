# Native dependency manifest

This manifest covers the arm64 dylibs recursively selected by
`bundle-mpv.sh` from IINA v1.5.0. The application does not ship IINA's
executable, UI code, icons, plugins, or resources.

| Bundled dylib(s) | Project / pinned source | License family |
|---|---|---|
| `libmpv.2` | mpv 0.41.0 | GPL-2.0-or-later / LGPL-2.1-or-later by build configuration |
| `libavcodec.63`, `libavdevice.63`, `libavfilter.12`, `libavformat.63`, `libavutil.61`, `libswresample.7`, `libswscale.10` | FFmpeg 9.0.1 | LGPL-2.1-or-later / GPL-2.0-or-later by build configuration |
| `libass.9` | libass 0.17.5 | ISC |
| `libarchive.13` | libarchive 3.8.8 | BSD-2-Clause |
| `libbluray.3` | libbluray 1.4.1 | LGPL-2.1-or-later |
| `libluajit-5.1.2` | LuaJIT pinned commit in dependency scripts | MIT |
| `librubberband.3` | Rubber Band 4.0.0 | GPL-2.0-or-later |
| `libuchardet.0` | uchardet 0.0.8 | MPL-1.1 |
| `libzimg.2` | zimg 3.0.6 | WTFPL-2.0 |
| `libjpeg.62` | libjpeg-turbo 3.1.4.1 | BSD-3-Clause / IJG / zlib |
| `libfreetype.6` | FreeType 2.14.3 | FTL / GPL-2.0-or-later |
| `libfribidi.0` | FriBidi 1.0.16 | LGPL-2.1-or-later |
| `libharfbuzz.0` | HarfBuzz 14.2.1 | MIT |
| `libfontconfig.1` | fontconfig 2.18.1 | MIT |
| `libunibreak.7` | libunibreak 7.0 | zlib |
| `libplacebo.360` | libplacebo 7.360.1 | LGPL-2.1-or-later |
| `libdav1d.7` | dav1d 1.5.3 | BSD-2-Clause |
| `libjxl.0.11`, `libjxl_cms.0.11`, `libjxl_threads.0.11` | JPEG XL 0.11.2 and its pinned submodules | BSD-3-Clause and dependency licenses |
| `libSvtAv1Enc.4` | SVT-AV1 4.2.0 | BSD-3-Clause |
| `libogg.0` | libogg 1.3.6 | BSD-3-Clause |
| `libvorbis.0`, `libvorbisenc.2` | libvorbis 1.3.7 | BSD-3-Clause |
| `libspeex.1` | Speex 1.2.1 | BSD-3-Clause |
| `libsoxr.0` | libsoxr 0.1.3 | LGPL-2.1-or-later |
| `libwebp.7`, `libwebpmux.3`, `libsharpyuv.0` | libwebp 1.6.0 | BSD-3-Clause |
| `liblcms2.2` | Little CMS 2.19 | MIT |
| `libmujs` | MuJS 1.3.9 | ISC |
| `libbs2b.0` | libbs2b 3.1.0 | MIT |
| `liblz4.1` | LZ4 1.10.0 | BSD-2-Clause |
| `libzstd.1` | Zstandard 1.5.7 | BSD-3-Clause / GPL-2.0-only dual license |
| `libbrotlicommon.1`, `libbrotlidec.1`, `libbrotlienc.1` | Brotli source pinned through the JPEG XL dependency closure | MIT |
| `libudfread.3` | libudfread 1.2.0 | LGPL-2.1-or-later |

The produced app includes 46 source artifacts: every URL-pinned dependency in
IINA's build manifest, IINA and mpv, Rubber Band, libjxl, libplacebo, and the
exact enabled libplacebo and libjxl submodule revisions. URL artifacts are
checked against IINA's published build hashes; the git-tag/commit archives have
their delivered SHA-256 values in `ADDITIONAL-SOURCE-SHA256SUMS.txt`. The 41 component notice
groups contain the source projects' actual license, copying, copyright, notice,
authors, FTL or OFL files—not merely a license-family label. IINA's exact build
scripts at commit `9abe2c1c66efa21a7a199a678d1ab55be72e0301` preserve patches,
compiler flags and install-name steps. `PROVENANCE.txt` records the closure size.

The public repository's AGPL source archive covers the host and C shim. Release
publication must retain `ThirdPartyLicenses` and `CorrespondingSource`; omitting
either is a release-blocking license defect.
