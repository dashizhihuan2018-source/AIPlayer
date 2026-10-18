import Foundation
import Darwin

enum DesktopAppIdentity {
    static func versionLabel(bundle: Bundle = .main) -> String {
        let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let version = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "万能AI播放器 \((version?.isEmpty == false ? version : nil) ?? "未知版本")"
    }

    static func versionLabelJSON(bundle: Bundle = .main) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: versionLabel(bundle: bundle), options: [.fragmentsAllowed])
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "AIPlayer.identity", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法编码应用版本"])
        }
        return json
    }
}

enum DesktopPolicy {
    static let port = 18784
    static let baseURL = URL(string: "http://127.0.0.1:\(port)")!

    // All 22 real providers in the last official built-in list before removal:
    // LibreSpark/LibreTV@0d991bcc23d8e978bab2af13bb130ba3352642d4, js/config.js.
    // Excludes example.com testSource; ffzy uses the checked HTTPS endpoint.
    // Preserve the first three keys shipped locally; append, never reorder.
    // Availability and content licensing are not guaranteed. See docs/SOURCES.md.
    static let defaultSources = #"""
    [
      {"name":"暴风资源","url":"https://bfzyapi.com/api.php/provide/vod","isAdult":false},
      {"name":"非凡影视","url":"https://api.ffzyapi.com/api.php/provide/vod","isAdult":false},
      {"name":"360资源","url":"https://360zy.com/api.php/provide/vod","isAdult":false},
      {"name":"电影天堂资源","url":"http://caiji.dyttzyapi.com/api.php/provide/vod","detail":"http://caiji.dyttzyapi.com","isAdult":false},
      {"name":"如意资源","url":"https://cj.rycjapi.com/api.php/provide/vod","isAdult":false},
      {"name":"天涯资源","url":"https://tyyszy.com/api.php/provide/vod","isAdult":false},
      {"name":"小猫咪资源","url":"https://zy.xmm.hk/api.php/provide/vod","isAdult":false},
      {"name":"黑木耳","url":"https://json.heimuer.xyz/api.php/provide/vod","detail":"https://heimuer.tv","isAdult":false},
      {"name":"iqiyi资源","url":"https://www.iqiyizyapi.com/api.php/provide/vod","isAdult":false},
      {"name":"卧龙资源","url":"https://wolongzyw.com/api.php/provide/vod","isAdult":false},
      {"name":"华为吧资源","url":"https://cjhwba.com/api.php/provide/vod","isAdult":false},
      {"name":"极速资源","url":"https://jszyapi.com/api.php/provide/vod","detail":"https://jszyapi.com","isAdult":false},
      {"name":"豆瓣资源","url":"https://dbzy.tv/api.php/provide/vod","isAdult":false},
      {"name":"魔爪资源","url":"https://mozhuazy.com/api.php/provide/vod","isAdult":false},
      {"name":"魔都资源","url":"https://www.mdzyapi.com/api.php/provide/vod","isAdult":false},
      {"name":"最大资源","url":"https://api.zuidapi.com/api.php/provide/vod","isAdult":false},
      {"name":"樱花资源","url":"https://m3u8.apiyhzy.com/api.php/provide/vod","isAdult":false},
      {"name":"百度云资源","url":"https://api.apibdzy.com/api.php/provide/vod","isAdult":false},
      {"name":"无尽资源","url":"https://api.wujinapi.me/api.php/provide/vod","isAdult":false},
      {"name":"旺旺短剧","url":"https://wwzy.tv/api.php/provide/vod","isAdult":false},
      {"name":"iKun资源","url":"https://ikunzyapi.com/api.php/provide/vod","isAdult":false},
      {"name":"量子资源站","url":"https://cj.lziapi.com/api.php/provide/vod","isAdult":false}
    ]
    """#

    static func canBind(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    static func allowsNavigation(_ url: URL, port: Int = port) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && url.port == port
            && url.user == nil && url.password == nil
    }

    static func serverEnvironment(home: String, temp: String, password: String) -> [String: String] {
        ["HOME": home, "TMPDIR": temp, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
         "LANG": "zh_CN.UTF-8", "NODE_ENV": "production", "HOSTNAME": "127.0.0.1",
         "PORT": String(port), "PASSWORD": password, "COOKIE_SECURE": "false",
         "NEXT_TELEMETRY_DISABLED": "1", "DEFAULT_RECOMMEND_SOURCE": "douban",
         "DEFAULT_SOURCES": defaultSources]
    }
}
