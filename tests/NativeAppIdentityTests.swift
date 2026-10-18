import Foundation

@main struct NativeAppIdentityTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIPlayerIdentity-\(UUID().uuidString).bundle")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plist: [String: Any] = [
            "CFBundleIdentifier": "cn.nankong.aiplayer.identity-test",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "9.8.7-test"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        guard let bundle = Bundle(url: root) else { preconditionFailure("temporary version fixture must form a Bundle") }

        let label = DesktopAppIdentity.versionLabel(bundle: bundle)
        precondition(label == "万能AI播放器 9.8.7-test", "label must interpolate the real bundle version")
        precondition(!label.contains("appVersion"), "label must not ship the Swift variable name as literal text")

        let json = try DesktopAppIdentity.versionLabelJSON(bundle: bundle)
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? String
        precondition(decoded == label, "diagnostics JavaScript literal must preserve the dynamic bundle label")
        print("Native app identity: real Bundle version label and diagnostics JSON PASS")
    }
}
