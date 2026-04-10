//
//  QuickCalcUITests.swift
//  QuickCalcUITests
//
//  Created by Berke on 7.04.2026.
//

import XCTest

final class QuickCalcUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMenuBarUIRequiresManualVerification() throws {
        throw XCTSkip("The agent menu bar UI is verified manually.")
    }
}
