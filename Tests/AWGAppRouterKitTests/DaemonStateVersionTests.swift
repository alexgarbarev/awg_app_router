import XCTest
@testable import AWGAppRouterKit

/// Совместимость снимка состояния по релизным версиям (сверка «устарел»
/// теперь по версии, а не по md5 бинаря).
final class DaemonStateVersionTests: XCTestCase {

    func testRoundTripCarriesVersion() throws {
        let s = DaemonState(bootID: "b", daemonVersion: "9.9.9")
        let data = try JSONEncoder().encode(s)
        let d = try JSONDecoder().decode(DaemonState.self, from: data)
        XCTAssertEqual(d.daemonVersion, "9.9.9")
    }

    /// старый демон присылает JSON без поля daemonVersion → декодится пустой,
    /// GUI обязан посчитать такой демон «устаревшим» (не паниковать)
    func testOldDaemonJSONWithoutVersionDecodesEmpty() throws {
        let json = #"{"generation":3,"bootID":"x","mode":"running","boxRunning":true,"tunUp":true,"sealed":false,"lastError":"","servers":[],"appRoutes":[],"autostartConnect":false}"#
        let d = try JSONDecoder().decode(DaemonState.self, from: Data(json.utf8))
        XCTAssertEqual(d.daemonVersion, "")
        XCTAssertEqual(d.generation, 3)
    }
}
