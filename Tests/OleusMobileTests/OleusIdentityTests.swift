import XCTest
@testable import OleusMobile

final class OleusIdentityTests: XCTestCase {
    private let suiteName = "io.oleus.tests.identity"

    override func setUp() {
        super.setUp()
        // Isolate from the app's real UserDefaults.
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        OleusIdentity.defaults = defaults
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        OleusIdentity.defaults = .standard
        super.tearDown()
    }

    func testAnonIdIsGeneratedAndStable() {
        let a = OleusIdentity.anonId
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a, OleusIdentity.anonId, "anon id is stable across reads")
    }

    func testDistinctIdDefaultsToAnonBeforeIdentify() {
        XCTAssertEqual(OleusIdentity.distinctId, OleusIdentity.anonId)
    }

    func testIdentifySwitchesDistinctIdButKeepsAnon() {
        let anon = OleusIdentity.anonId
        OleusIdentity.identify("user-1")
        XCTAssertEqual(OleusIdentity.distinctId, "user-1")
        XCTAssertEqual(OleusIdentity.anonId, anon, "identify must not rotate the anon id")
    }

    func testResetRotatesAnonAndClearsIdentity() {
        let anon = OleusIdentity.anonId
        OleusIdentity.identify("user-1")
        OleusIdentity.reset()
        XCTAssertNotEqual(OleusIdentity.anonId, anon, "reset rotates the anon id")
        XCTAssertEqual(OleusIdentity.distinctId, OleusIdentity.anonId,
                       "after reset, distinct id falls back to the new anon id")
    }

    func testIdentityPersistsAcrossReadsViaBackingStore() {
        OleusIdentity.identify("user-42")
        // simulate a fresh read path
        XCTAssertEqual(OleusIdentity.distinctId, "user-42")
    }
}
