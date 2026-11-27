import Foundation

/// Одна строка UI: приложение (или CLI-бинарь), чей трафик идёт в туннель.
public struct AppRule: Codable, Equatable, Identifiable {
    public var id: String { path }
    public var name: String            // "MyApp"
    public var path: String           // /Applications/MyApp.app/Contents/MacOS/MyApp
    public var bundlePath: String?    // /Applications/MyApp.app — regex по всему бандлу (хелперы в Frameworks/)
    public var includeChildren: Bool  // хелперы Electron/Chromium матчатся regex по каталогу .app
    public var isCLI: Bool            // матчится по process_name (basename), без пути
    public var serverID: String       // "srv-1"; "" = первый включённый сервер

    public init(name: String, path: String, bundlePath: String? = nil,
                includeChildren: Bool = true, isCLI: Bool = false, serverID: String = "") {
        self.name = name
        self.path = path
        self.bundlePath = bundlePath
        self.includeChildren = includeChildren
        self.isCLI = isCLI
        self.serverID = serverID
    }

    // старые state.json без serverID — decodeIfPresent
    private enum CodingKeys: String, CodingKey {
        case name, path, bundlePath, includeChildren, isCLI, serverID
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        bundlePath = try c.decodeIfPresent(String.self, forKey: .bundlePath)
        includeChildren = try c.decodeIfPresent(Bool.self, forKey: .includeChildren) ?? true
        isCLI = try c.decodeIfPresent(Bool.self, forKey: .isCLI) ?? false
        serverID = try c.decodeIfPresent(String.self, forKey: .serverID) ?? ""
    }

    /// sing-box route rule для этого приложения на указанный outbound.
    /// Хелперы (Chromium/Electron: main, GPU, Renderer, network service) живут в
    /// Contents/Frameworks/ — их ловит ТОЛЬКО regex по корню бандла, не по бинарю.
    public func routeRule(outbound: String) -> [String: Any] {
        if isCLI {
            return ["action": "route", "outbound": outbound, "process_name": name]
        }
        if includeChildren, let bundle = bundlePath ?? Self.bundleFromPath(path) {
            return ["action": "route", "outbound": outbound,
                    "process_path_regex": "^" + AWGProfileTools.regexEscaped(bundle) + "/.*"]
        }
        return ["action": "route", "outbound": outbound, "process_path": path]
    }

    /// Самолечение для записей, сохранённых старыми сборками (bundlePath nil).
    static func bundleFromPath(_ path: String) -> String? {
        guard let r = path.range(of: "/Contents/") else { return nil }
        return String(path[..<r.lowerBound])
    }
}

public enum AWGProfileTools {
    /// Экранирование метасимволов regex (sing-box: Go RE2; слэш не экранируем).
    public static func regexEscaped(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            if "^$.[]|()?*+{}\\".unicodeScalars.contains(ch) { out.append("\\") }
            out.unicodeScalars.append(ch)
        }
        return out
    }
}
