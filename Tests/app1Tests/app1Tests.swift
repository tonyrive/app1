import XCTest
@testable import app1

final class app1Tests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        XCTAssertEqual(app1().text, "Hello, World!")
    }

    static var allTests = [
        ("testExample", testExample),
    ]
}
