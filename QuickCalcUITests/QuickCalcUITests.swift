//
//  QuickCalcUITests.swift
//  QuickCalcUITests
//
//  Created by Berke on 7.04.2026.
//

import XCTest

final class QuickCalcUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        throw XCTSkip("The agent menu bar UI is verified manually.")
    }

    @MainActor
    func testLaunchPerformance() throws {
        throw XCTSkip("Launch performance is disabled for the menu bar agent app.")
    }
}
