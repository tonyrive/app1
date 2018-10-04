import XCTest

import app1Tests

var tests = [XCTestCaseEntry]()
tests += app1Tests.allTests()
XCTMain(tests)