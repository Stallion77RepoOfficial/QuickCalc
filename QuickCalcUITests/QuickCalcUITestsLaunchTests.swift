//
//  QuickCalcUITestsLaunchTests.swift
//  QuickCalcUITests
//
//  Created by Berke on 7.04.2026.
//

import XCTest

final class QuickCalcUITestsLaunchTests: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        throw XCTSkip("The menu bar agent app does not support screenshot-based launch tests.")
    }
}
