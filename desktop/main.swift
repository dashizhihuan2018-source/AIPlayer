import AppKit
import WebKit
import Security
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var webView: WKWebView!
    var statusLabel: NSTextField!
    var progress: NSProgressIndicator!
    var retryButton: NSButton!
    var statusView: NSView!
    var nativePlayer: NativePlayerController!
    var titlebarDrag: NativeTitlebarDragController?
    var server: Process?
    var logHandle: FileHandle?
    var lockFD: Int32 = -1
    var attempt = UUID()
    var quitting = false
    var password = ""
    var pendingExternalURLs: [URL] = []
    let files = FileManager.default
    let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LibreTV Desktop")
    let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LibreTV Desktop")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try files.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.createDirectory(at: logs, withIntermediateDirectories: true)
            lockFD = Darwin.open(support.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                NSRunningApplication.runningApplications(withBundleIdentifier: "cn.nankong.libretv.desktop")
                    .first(where: { $0.processIdentifier != getpid() })?.activate(options: [.activateAllWindows])
                NSApp.terminate(nil)
                return
            }
            let secret = support.appendingPathComponent("local-password")
            if files.fileExists(atPath: secret.path) {
                password = try String(contentsOf: secret, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                guard password.count >= 32 else { throw NSError(domain: "LibreTV", code: 1, userInfo: [NSLocalizedDescriptionKey: "本机认证配置损坏，请保留数据并联系维护者。 "]) }
            } else {
                var bytes = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                    throw NSError(domain: "LibreTV", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建安全的本机访问凭证。"])
                }
                password = Data(bytes).base64EncodedString()
                try password.write(to: secret, atomically: true, encoding: .utf8)
            }
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
            try setupWindow()
            setupMenus()
            startServer()
        } catch {
            let alert = NSAlert()
            alert.messageText = "万能AI播放器 无法启动"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func setupWindow() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "万能AI播放器"
        configureImmersivePlayerWindow(window)
        window.minSize = NSSize(width: 850, height: 600)
        window.center()
        window.setFrameAutosaveName("LibreTV.MainWindow")
        let rootView = DropContainerView(frame: window.contentView!.bounds)
        rootView.autoresizingMask = [.width, .height]
        window.contentView = rootView
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: "desktop")
        webView = PlayerWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        window.contentView!.addSubview(webView)
        nativePlayer = try NativePlayerController(webView: webView, window: window, container: rootView, supportDirectory: support)
        if !pendingExternalURLs.isEmpty {
            nativePlayer.openFromSystem(pendingExternalURLs)
            pendingExternalURLs.removeAll(keepingCapacity: false)
        }
        rootView.onFiles = { [weak self] urls in self?.nativePlayer.openFromSystem(urls) }
        (webView as? PlayerWebView)?.onFiles = { [weak self] urls in self?.nativePlayer.openFromSystem(urls) }
        statusView = NSView(frame: window.contentView!.bounds)
        statusView.autoresizingMask = [.width, .height]
        statusView.wantsLayer = true
        statusView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "万能AI播放器")
        title.font = .systemFont(ofSize: 32, weight: .semibold)
        statusLabel = NSTextField(wrappingLabelWithString: "正在启动本地服务…")
        statusLabel.alignment = .center
        statusLabel.preferredMaxLayoutWidth = 560
        progress = NSProgressIndicator()
        progress.style = .spinning
        progress.startAnimation(nil)
        retryButton = NSButton(title: "重试", target: self, action: #selector(retry))
        retryButton.isHidden = true
        [title, statusLabel, progress, retryButton].forEach { stack.addArrangedSubview($0) }
        statusView.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: statusView.centerXAnchor), stack.centerYAnchor.constraint(equalTo: statusView.centerYAnchor), stack.widthAnchor.constraint(lessThanOrEqualToConstant: 580)])
        window.contentView!.addSubview(statusView)
        titlebarDrag = NativeTitlebarDragController(window: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setupMenus() {
        let menu = NSMenu()
        func submenu(_ name: String) -> NSMenu {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: name)
            item.submenu = sub
            menu.addItem(item)
            return sub
        }
        func add(_ sub: NSMenu, _ title: String, _ selector: Selector, _ key: String = "") {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            sub.addItem(item)
        }
        let app = submenu("万能AI播放器")
        add(app, "关于 万能AI播放器", #selector(about))
        app.addItem(.separator())
        add(app, "隐藏 万能AI播放器", #selector(hide), "h")
        add(app, "退出 万能AI播放器", #selector(quit), "q")
        let file = submenu("文件")
        add(file, "打开本地媒体…", #selector(openLocalMedia), "o")
        add(file, "打开视频链接…", #selector(openVideo), "l")
        file.addItem(.separator())
        add(file, "查看 GIF 成果文件夹", #selector(openGIFFolder))
        let edit = submenu("编辑")
        for (name, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: name, action: Selector(selector), keyEquivalent: key)
        }
        let view = submenu("浏览")
        add(view, "首页", #selector(home), "1")
        add(view, "后退", #selector(back), "[")
        add(view, "前进", #selector(forward), "]")
        add(view, "重新载入", #selector(reload), "r")
        add(view, "切换全屏", #selector(fullscreen), "f")
        view.items.last?.keyEquivalentModifierMask = [.command, .control]
        let help = submenu("帮助")
        add(help, "原生播放示例（Apple）", #selector(playDemo))
        add(help, "在线播放示例（Apple）", #selector(playWebDemo))
        add(help, "使用说明", #selector(openHelp))
        add(help, "打开日志文件夹", #selector(openLogs))
        add(help, "保存诊断快照", #selector(diagnostics))
        NSApp.mainMenu = menu
    }

    func startServer() {
        guard DesktopPolicy.canBind(port: UInt16(DesktopPolicy.port)) else {
            fail("本机端口 \(DesktopPolicy.port) 已被其他程序占用。请释放该端口后重试；万能AI播放器不会关闭其他程序。")
            return
        }
        let resources = Bundle.main.resourceURL!
        let node = resources.appendingPathComponent("runtime/node")
        let launcher = resources.appendingPathComponent("serve.cjs")
        guard files.isExecutableFile(atPath: node.path), files.fileExists(atPath: launcher.path) else {
            fail("应用文件不完整，请从完整安装包重新安装。")
            return
        }
        attempt = UUID()
        let currentAttempt = attempt
        statusView.isHidden = false
        statusLabel.stringValue = "正在启动本地服务…"
        retryButton.isHidden = true
        progress.startAnimation(nil)
        let logURL = logs.appendingPathComponent("server.log")
        if let size = (try? files.attributesOfItem(atPath: logURL.path)[.size]) as? NSNumber, size.intValue > 5_000_000 {
            try? files.removeItem(at: logs.appendingPathComponent("server.previous.log"))
            try? files.moveItem(at: logURL, to: logs.appendingPathComponent("server.previous.log"))
        }
        if !files.fileExists(atPath: logURL.path) { files.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        do {
            logHandle = try FileHandle(forWritingTo: logURL)
            try logHandle?.seekToEnd()
            let process = Process()
            process.executableURL = node
            process.arguments = [launcher.path]
            process.currentDirectoryURL = resources
            process.environment = DesktopPolicy.serverEnvironment(home: files.homeDirectoryForCurrentUser.path, temp: NSTemporaryDirectory(), password: password)
            process.standardOutput = logHandle
            process.standardError = logHandle
            process.terminationHandler = { [weak self] p in
                DispatchQueue.main.async {
                    guard let self, !self.quitting, self.attempt == currentAttempt else { return }
                    self.fail("本地服务已停止（状态 \(p.terminationStatus)）。端口可能被占用，可查看日志后重试。")
                }
            }
            server = process
            try process.run()
            waitForServer(until: Date().addingTimeInterval(40), id: currentAttempt)
        } catch { fail("无法启动本地服务：\(error.localizedDescription)") }
    }

    func waitForServer(until deadline: Date, id: UUID) {
        guard attempt == id, !quitting, server?.isRunning == true else { return }
        var request = URLRequest(url: DesktopPolicy.baseURL.appendingPathComponent("api/status"))
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self, self.attempt == id, !self.quitting, self.server?.isRunning == true else { return }
                if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   (response as? HTTPURLResponse)?.statusCode == 200, json["version"] as? String == "2.16.12" {
                    self.authenticate(id: id)
                } else if Date() < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.waitForServer(until: deadline, id: id) }
                } else {
                    self.fail("本地服务启动超时，请查看日志并重试。")
                    self.stopServer()
                }
            }
        }.resume()
    }

    func authenticate(id: UUID) {
        statusLabel.stringValue = "正在打开 万能AI播放器…"
        var request = URLRequest(url: DesktopPolicy.baseURL.appendingPathComponent("api/auth"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["password": password])
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self, self.attempt == id, !self.quitting else { return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    self.fail("本机访问认证失败，请查看日志后重试。")
                    return
                }
                var headers = [String: String]()
                http.allHeaderFields.forEach { headers[String(describing: $0.key)] = String(describing: $0.value) }
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: DesktopPolicy.baseURL)
                guard !cookies.isEmpty else { self.fail("无法建立本机访问会话。"); return }
                let group = DispatchGroup()
                for cookie in cookies {
                    group.enter()
                    self.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { group.leave() }
                }
                group.notify(queue: .main) {
                    guard self.attempt == id, !self.quitting else { return }
                    self.webView.load(URLRequest(url: DesktopPolicy.baseURL))
                }
            }
        }.resume()
    }

    func fail(_ message: String) {
        statusView?.isHidden = false
        statusLabel?.stringValue = message
        progress?.stopAnimation(nil)
        retryButton?.isHidden = false
    }

    func stopServer() {
        attempt = UUID()
        if let process = server, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        server = nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting = true
        nativePlayer?.shutdown()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "desktop")
        webView?.stopLoading()
        let process = server
        stopServer()
        DispatchQueue.global().async {
            process?.waitUntilExit()
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { try? logHandle?.close() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let nativePlayer { nativePlayer.openFromSystem(urls) }
        else { pendingExternalURLs.append(contentsOf: urls) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        statusView.isHidden = true
        progress.stopAnimation(nil)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        nativePlayer?.pageWillNavigate()
        if let url = webView.url, !DesktopPolicy.allowsNavigation(url) {
            nativePlayer?.handle(.hideVideo) { _ in }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { fail("页面未能加载：\(error.localizedDescription)") }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { decisionHandler(.download); return }
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        if DesktopPolicy.allowsNavigation(url) { decisionHandler(.allow); return }
        if action.navigationType == .linkActivated, ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if DesktopPolicy.allowsNavigation(url) { webView.load(URLRequest(url: url)) }
            else if ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        }
        return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = "万能AI播放器"; alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = "万能AI播放器"; alert.informativeText = message
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = suggestedFilename
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.url : nil) }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let alert = NSAlert(); alert.messageText = "下载未完成"; alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard NativeBridgePolicy.isTrustedFrame(isMainFrame: message.frameInfo.isMainFrame, sourceURL: message.frameInfo.request.url) else { return }
        guard let body = message.body as? [String: Any],
              let id = body["id"] as? String, !id.isEmpty, id.count <= 128,
              let command = body["command"] as? String,
              let args = body["args"] as? [String: Any] else {
            return
        }
        do {
            let request = try NativeBridgePolicy.validateRequest(command: command, args: args, authorizedLocalIDs: nativePlayer.authorizedLocalIDs)
            nativePlayer.handle(request) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let value): self?.nativePlayer.emit(["id": id, "result": value, "error": NSNull()])
                    case .failure(let error): self?.nativePlayer.emit(["id": id, "result": NSNull(), "error": error.localizedDescription])
                    }
                }
            }
        } catch {
            nativePlayer.emit(["id": id, "result": NSNull(), "error": error.localizedDescription])
        }
    }

    @objc func retry() { stopServer(); DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { self.startServer() } }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func hide() { NSApp.hide(nil) }
    @objc func home() { webView.load(URLRequest(url: DesktopPolicy.baseURL)) }
    @objc func back() { webView.goBack() }
    @objc func forward() { webView.goForward() }
    @objc func reload() { webView.reload() }
    @objc func fullscreen() { nativePlayer?.toggleFullscreenFromMenu() }
    @objc func openGIFFolder() {
        do { try nativePlayer?.openGIFOutputFolder() }
        catch { nativePlayer?.emitErrorState(error) }
    }
    @objc func openLocalMedia() {
        nativePlayer.pickMedia { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let items):
                self.nativePlayer.openAuthorizedItems(items)
            case .failure(let error): self.nativePlayer.emitErrorState(error)
            }
        }
    }
    @objc func openLogs() { NSWorkspace.shared.open(logs) }
    @objc func openHelp() { NSWorkspace.shared.open(Bundle.main.resourceURL!.appendingPathComponent("使用说明.html")) }
    @objc func about() {
        let alert = NSAlert()
        alert.messageText = DesktopAppIdentity.versionLabel()
        alert.informativeText = "基于 LibreSpark/LibreTV 2.16.12 与独立 libmpv 引擎的桌面播放器，非上游官方发行。\n桌面封装：Nankong\n上游许可证：AGPL-3.0-or-later；libmpv 与依赖许可证见应用资源 ThirdPartyLicenses。完整源码见 Source.tar.gz。\n已预置原项目历史列表中的22个公开接口，第三方可用性与内容授权不由本应用保证。\nAI为应用名称，本版本尚未接入AI服务。"
        alert.beginSheetModal(for: window)
    }
    func play(url: String, title: String) {
        guard let media = URL(string: url), ["http", "https"].contains(media.scheme?.lowercased() ?? ""),
              media.host != nil, media.user == nil, media.password == nil else { return }
        nativePlayer.openURLFromSystem(media, name: title)
    }
    @objc func playDemo() {
        play(url: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8", title: "Apple 官方 HLS 测试影片")
    }
    @objc func playWebDemo() {
        var components = URLComponents(url: DesktopPolicy.baseURL.appendingPathComponent("watch"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "url", value: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8"),
            URLQueryItem(name: "title", value: "Apple示例")
        ]
        if let url = components?.url { webView.load(URLRequest(url: url)) }
    }
    @objc func openVideo() {
        let alert = NSAlert(); alert.messageText = "打开视频链接"; alert.informativeText = "粘贴你有权观看的 HTTPS / HTTP 视频地址（HLS 或 MP4）。"
        alert.addButton(withTitle: "播放"); alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 450, height: 24))
        input.placeholderString = "https://…/video.m3u8"
        alert.accessoryView = input
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { self.play(url: input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), title: "视频链接") }
        }
        window.makeFirstResponder(input)
    }
    @objc func diagnostics() {
        let labelJSON = (try? DesktopAppIdentity.versionLabelJSON()) ?? "\"万能AI播放器\""
        let js = """
        JSON.stringify({app:\(labelJSON),date:new Date().toISOString(),page:location.pathname,title:document.title,
          text:document.body.innerText.slice(0,12000),media:[...document.querySelectorAll('video')].map(v=>({currentTime:v.currentTime,duration:Number.isFinite(v.duration)?v.duration:null,paused:v.paused,readyState:v.readyState,width:v.videoWidth,height:v.videoHeight,error:v.error?{code:v.error.code,message:v.error.message}:null}))})
        """
        webView.evaluateJavaScript(js) { result, _ in
            if let result = result as? String { try? result.write(to: self.logs.appendingPathComponent("diagnostics.json"), atomically: true, encoding: .utf8) }
        }
        webView.takeSnapshot(with: nil) { image, _ in
            if let data = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: self.logs.appendingPathComponent("snapshot.png"))
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
