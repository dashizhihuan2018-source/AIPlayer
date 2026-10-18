# 万能AI播放器 · AIPlayer

macOS Apple Silicon 本地播放器与多来源影视搜索工作区，基于 [LibreSpark/LibreTV](https://github.com/LibreSpark/LibreTV) 2.16.12 和独立 libmpv 引擎。非 LibreSpark、IINA 或 OmniPlayer 官方发行，不包含 OmniPlayer 的专有代码或素材。

本仓库为 **V1.1.0（内部 build16）的干净公开源码快照**，不带私有研发仓库历史、用户媒体或诊断资料。本次只公开源码，没有 GitHub Release、安装包或 Apple 公证；AI 是产品名称，此版本尚未接入 AI 服务或云端用户账号系统。

## 当前功能

- 中轴居中的星空首页、既有 P/AIPlayer Logo，“全网资源 一键搜索”进入发现与搜索。
- 原生选择/拖入本地媒体、播放队列、播放/暂停、快退/快进、进度定位、速度、音量、全屏与画中画。
- 截图、GIF、视频缩略图/时间线海报及视频片段自动保存。GIF 同一按钮开始/停止，不弹保存或预览卡片；悬停或聚焦 GIF 图标显示速度、帧率、分辨率和打开成果文件夹子菜单。
- GIF 默认最高宽度 640、20 FPS，可选最高宽度 3840（4K），低分辨率源不放大；采样跟随实际播放速度。build16 修复原先 4K 高倍速取帧/缓存停顿：自有 UHD 素材在 0.5×、1×、2×、两档输出下，每约 1.2 秒录得 25 次采样；真实 3840×2160 GIF 解码通过。GIF 本身为调色板格式，并非视频色彩无损；不承诺所有片源/机器均达到目标帧率，连续动态实机观感尚待验收。
- 恢复原上游历史清单的 22 个公开接口，无需手填初始来源。来源出处和兼容边界见 [来源说明](docs/SOURCES.md)。不保证全网全量、来源可用性或内容观看/下载授权。

投屏、字幕烧录、AI 宣传文案/海报、云登录及完整专业播放器功能复刻不属于本版本已完成能力。详细测试与限制见 [验证范围](docs/VERIFICATION.md)。

## 隐私与网络

服务仅监听 `127.0.0.1:18784`。本地随机认证、配置、观看历史和成果文件不进入公开源码；认证不能当作同一 macOS 用户进程间的安全隔离。没有公开管理员默认口令。

搜索、推荐、封面、来源订阅和在线视频会访问外部服务，服务方可能看到 IP、查询和资源请求，不是全离线或匿名播放器。上游“发布为链接”是主动向外部服务上传来源列表的功能，不要提交私人订阅或凭据。更多数据位置与边界见 [隐私说明](docs/PRIVACY.md)。

## 本机重建

要求 macOS 13.5+、Apple Silicon、Xcode Command Line Tools、官方 Node.js 24 arm64（或含 arm64 的 universal 版本）。本机旧系统未逐版测试。

```bash
cd upstream
npm ci --ignore-scripts --no-audit --no-fund
npm test -- --maxWorkers=2 --minWorkers=1
npm run typecheck
cd ..
swiftc -parse-as-library desktop/Policy.swift tests/PolicyTests.swift -o /tmp/aiplayer-policy-tests
/tmp/aiplayer-policy-tests
bash desktop/build.sh
```

`desktop/build.sh` 在需要时从固定来源下载并校验原生依赖，下载与来源收集需要联网，详见 [原生依赖](desktop/NATIVE_DEPENDENCIES.md)。`NODE_BINARY` 可指定 Node 24 可执行文件。构建拒绝覆盖已有 `dist/万能AI播放器.app`，不隐式安装、替换当前 App 或删除用户数据。

构建后如需安装，先正常退出当前应用、备份旧包，再将成品放入 `/Applications`。不要同时运行相同 bundle ID 的多个副本。本次公开快照没有在另一台干净 Mac 完整重建/安装验收。

原生引擎测试需要自行准备有权使用的媒体及依赖：`bash tests/run-native-engine-tests.sh /absolute/path/to/owned-timecode.mp4 [owned-4k.mp4]`。媒体不随仓库提供，不能把缺少 fixture 的测试说成已通过。

## 许可与来源

上游固定 commit：`a24ad336a3f7c8a16ca93d1f1198e08ac6b7e943`，上游归档 SHA-256：`98d157338a61f17d4040403d24b321cd8c7fa24bca5d77e595e2545d5541e828`。

上游和本地软件修改遵循 **AGPL-3.0-or-later**，见 [LICENSE](LICENSE)、[NOTICE](NOTICE.md)。不把第三方既有许可改为非商业专用。品牌与星空视觉为独立生成资产，出处见 [素材说明](docs/ASSETS.md)。Node、libmpv、FFmpeg 及依赖保留各自许可；构建 App 必须保留 ThirdPartyLicenses 与 CorrespondingSource。

© 2026 Nankong（桌面改编部分）；LibreTV 及其他第三方权利归各自权利人。
