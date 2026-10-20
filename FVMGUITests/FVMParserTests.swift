import XCTest
@testable import fvm_gui

final class FVMParserTests: XCTestCase {
    func testVerifiedSDKFixture() throws {
        let items = try FVMParser().sdks(fixture("list-fvm-4.3.1.json"))
        XCTAssertEqual(items.map(\.name), ["3.47.2", "3.41.6"])
        XCTAssertTrue(items.allSatisfy(\.isSetup))
        XCTAssertNil(items.first?.channel)
    }
    func testVerifiedReleasesFixture() throws {
        let releases = try FVMParser().releases(fixture("releases-fvm-4.3.1.json"))
        XCTAssertEqual(releases.count, 5)
        XCTAssertEqual(releases.first?.channel, "beta")
        XCTAssertTrue(releases.contains { $0.channel == "stable" })
    }
    func testMalformedAndNonJSONSuccessAreRejected() {
        for text in ["", "Failed to retrieve releases", "{}", "{\"versions\":[{}]}"] {
            XCTAssertThrowsError(try FVMParser().releases(text))
        }
    }
    func testOptionalProjectPinAndUnknownFields() throws {
        let info = try FVMParser().project(#"{"project":{"name":"demo","isFlutter":true,"unknown":123}}"#)
        XCTAssertNil(info.version)
        XCTAssertTrue(info.isFlutter)
    }
    func testContextOnlyDecodesRequiredLink() throws {
        let url = try FVMParser().globalLink(#"{"context":{"globalCacheLink":"/tmp/default","environment":{"secret":"discard"}}}"#)
        XCTAssertEqual(url.path, "/tmp/default")
    }
}
