import Foundation
import Darwin

@main struct PolicyTests {
    static func main() {
        func allowed(_ value: String) -> Bool {
            DesktopPolicy.allowsNavigation(URL(string: value)!, port: 18784)
        }
        assert(allowed("http://127.0.0.1:18784/"))
        assert(allowed("http://127.0.0.1:18784/watch?id=1"))
        assert(!allowed("http://127.0.0.1:18785/"))
        assert(!allowed("http://localhost:18784/"))
        assert(!allowed("https://example.com/"))
        assert(!allowed("file:///etc/passwd"))
        assert(!allowed("http://attacker@127.0.0.1:18784/"))
        let env = DesktopPolicy.serverEnvironment(home: "/tmp/home", temp: "/tmp", password: "test-password")
        assert(env["HOSTNAME"] == "127.0.0.1")
        assert(env["PORT"] == "18784")
        assert(env["PASSWORD"] == "test-password")
        assert(env["COOKIE_SECURE"] == "false")
        assert(env["NODE_OPTIONS"] == nil)
        assert(env["NODE_TLS_REJECT_UNAUTHORIZED"] == nil)
        assert(env["LIVE_ALLOW_PRIVATE"] == nil)
        assert(env["DEFAULT_RECOMMEND_SOURCE"] == "douban")
        // A fresh install and an existing empty profile must not require manual API entry.
        let sourceData = Data((env["DEFAULT_SOURCES"] ?? "").utf8)
        guard let sources = try? JSONSerialization.jsonObject(with: sourceData) as? [[String: Any]] else {
            fatalError("Desktop must supply valid DEFAULT_SOURCES JSON")
        }
        assert(sources.count == 22)
        assert(Set(sources.compactMap { $0["url"] as? String }).count == 22)
        for source in sources {
            assert(!(source["name"] as? String ?? "").isEmpty)
            assert(source["isAdult"] as? Bool == false)
            let url = URL(string: source["url"] as! String)!
            assert(["http", "https"].contains(url.scheme ?? "") && url.user == nil && url.password == nil)
            assert(url.path == "/api.php/provide/vod")
        }
        assert(env["DEFAULT_SUBSCRIPTIONS"] == nil)
        assert(DesktopPolicy.canBind(port: 0))
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        assert(bound == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        assert(!DesktopPolicy.canBind(port: UInt16(bigEndian: address.sin_port)))
        print("Desktop policy: 110 assertions passed")
    }
}
