import XCTest
@testable import ClipboardForMac

@MainActor
final class PasteTargetTests: XCTestCase {
    func testWaitsForDelayedAppActivation() async {
        let target: pid_t = 42
        var checks = 0
        let activated = await PasteTarget.waitUntilFrontmost(
            target, maxChecks: 6, intervalNanoseconds: 0
        ) {
            checks += 1
            return checks >= 5 ? target : nil
        }

        XCTAssertTrue(activated)
        XCTAssertEqual(checks, 5)
    }

    func testDoesNotPasteWhenAnotherAppKeepsFocus() async {
        let activated = await PasteTarget.waitUntilFrontmost(42, maxChecks: 3, intervalNanoseconds: 0) { 73 }
        XCTAssertFalse(activated)
    }
}
