//
//  QuickCalcTests.swift
//  QuickCalcTests
//
//  Created by Berke on 7.04.2026.
//

import CoreGraphics
import Foundation
import Testing
@testable import QuickCalc

struct QuickCalcTests {

    @Test func handlesMultiDigitExpressions() throws {
        let value = try ExpressionEvaluator.evaluate("12+34/2")
        #expect(abs(value - 29) < 0.000_1)
    }

    @Test func respectsParenthesesAndUnaryMinus() throws {
        let value = try ExpressionEvaluator.evaluate("-(8-3)*4")
        #expect(abs(value + 20) < 0.000_1)
    }

    @Test func formatsWholeNumbersWithoutDecimalTail() {
        #expect(ExpressionEvaluator.format(42.0) == "42")
    }

    @Test func throwsOnDivisionByZero() {
        #expect(throws: ExpressionEvaluationError.divisionByZero) {
            try ExpressionEvaluator.evaluate("25/0")
        }
    }

    @Test func normalizesDownwardWritingIntoSingleLine() {
        let strokes = [
            Stroke(points: [StrokePoint(location: CGPoint(x: 40, y: 30), timestamp: 0)]),
            Stroke(points: [StrokePoint(location: CGPoint(x: 160, y: 82), timestamp: 1)]),
            Stroke(points: [StrokePoint(location: CGPoint(x: 280, y: 136), timestamp: 2)])
        ]

        let originalSlope = slope(of: strokes)
        let normalizedSlope = slope(of: HandwritingRecognizer.normalizedStrokesForRecognition(strokes))

        #expect(abs(originalSlope) > 0.3)
        #expect(abs(normalizedSlope) < 0.08)
    }

    @Test func cursorSessionStartsNewStrokeOnlyAfterExplicitRestart() {
        var session = CursorStrokeSession(minimumSampleDistance: 0.5, interpolationStep: 100)

        #expect(session.append(at: CGPoint(x: 4, y: 4), timestamp: 0) == false)

        session.begin(at: CGPoint(x: 10, y: 10), timestamp: 0)
        session.append(at: CGPoint(x: 18, y: 14), timestamp: 1)
        session.begin(at: CGPoint(x: 20, y: 16), timestamp: 2)

        #expect(session.isDrawing)
        #expect(session.strokes.count == 1)
        #expect(session.strokes[0].points.count == 3)

        session.end()

        #expect(!session.isDrawing)
        #expect(session.strokes.count == 1)

        session.begin(at: CGPoint(x: 40, y: 40), timestamp: 5)

        #expect(session.isDrawing)
        #expect(session.strokes.count == 2)
        #expect(session.strokes[1].points.count == 1)
    }

    @Test func cursorSessionInterpolatesLargeCursorJumps() {
        var session = CursorStrokeSession(minimumSampleDistance: 0.5, interpolationStep: 10)

        session.begin(at: CGPoint(x: 0, y: 0), timestamp: 0)
        session.append(at: CGPoint(x: 35, y: 0), timestamp: 1)

        let points = session.strokes[0].points
        let roundedXPositions = points.map { Int($0.location.x.rounded()) }

        #expect(points.count == 5)
        #expect(roundedXPositions == [0, 10, 20, 30, 35])
    }

    @Test func normalizesUniMERNetInlineOperators() {
        let normalized = HandwritingRecognizer.normalizedUniMERNetOutputForTesting("5 { + } 8")
        #expect(normalized == "5+8")
    }

    @Test func normalizesUniMERNetFractionsIntoArithmetic() {
        let normalized = HandwritingRecognizer.normalizedUniMERNetOutputForTesting("\\frac{12}{3}+4")
        #expect(normalized == "(12)/(3)+4")
    }

    @Test func trimsTrailingEqualsFromUniMERNetOutput() {
        let normalized = HandwritingRecognizer.normalizedUniMERNetOutputForTesting("5+8=")
        #expect(normalized == "5+8")
    }

    @Test func mapsCanvasCoordinatesIntoUprightRecognitionImage() {
        let mapped = HandwritingRecognizer.recognitionRenderPoint(
            from: CGPoint(x: 10, y: 20),
            scale: 2,
            xOffset: 3,
            yOffset: 5,
            renderHeight: 200
        )

        #expect(mapped.x == 23)
        #expect(mapped.y == 155)
    }

    @Test func hidesRawWorkerLogsFromUserFacingErrors() {
        let message = AppModel.userFacingMessage(
            for: UniMERNetServiceError.workerStartupFailed(
                details: "CustomVisionEncoderDecoderModel init VariableUniMerNetModel init..."
            )
        )

        #expect(message == "The AI model could not be started.")
        #expect(message.contains("CustomVision") == false)
        #expect(message.contains("VariableUniMerNetModel") == false)
    }

    @MainActor
    @Test func appModelDoesNotExposePreviewState() {
        let model = AppModel()
        let labels = Set(Mirror(reflecting: model).children.compactMap(\.label))

        #expect(labels.contains(where: { $0.localizedCaseInsensitiveContains("preview") }) == false)
    }

    private func slope(of strokes: [Stroke]) -> Double {
        let points = strokes.flatMap(\.points).map(\.location)
        let meanX = points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let meanY = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        let varianceX = points.reduce(CGFloat.zero) { partialResult, point in
            let delta = point.x - meanX
            return partialResult + (delta * delta)
        }
        let covariance = points.reduce(CGFloat.zero) { partialResult, point in
            partialResult + ((point.x - meanX) * (point.y - meanY))
        }

        return Double(covariance / max(varianceX, 0.000_1))
    }
}
