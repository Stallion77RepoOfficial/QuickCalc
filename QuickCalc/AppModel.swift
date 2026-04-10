//
//  AppModel.swift
//  QuickCalc
//
//  Created by Codex on 7.04.2026.
//

import CoreGraphics
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var menuBarTitle = ""
    @Published private(set) var lastExpression = ""
    @Published private(set) var lastResult = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isProcessing = false

    var showPopoverAction: (() -> Void)?
    var closeCanvasAction: (() -> Void)?

    private let recognizer = HandwritingRecognizer()

    func processDrawing(strokes: [Stroke], canvasSize: CGSize) async {
        guard !isProcessing else { return }
        isProcessing = true
        menuBarTitle = "..."

        do {
            let expression = try await recognizer.recognizeExpression(from: strokes, canvasSize: canvasSize)
            lastExpression = expression

            let value = try ExpressionEvaluator.evaluate(expression)
            let formatted = ExpressionEvaluator.format(value)

            lastResult = formatted
            errorMessage = nil
            menuBarTitle = Self.statusItemTitle(for: formatted)
        } catch {
            lastResult = ""
            errorMessage = Self.userFacingMessage(for: error)
            menuBarTitle = "!"
        }

        isProcessing = false
        closeCanvasAction?()
        showPopoverAction?()
    }

    nonisolated static func userFacingMessage(for error: Error) -> String {
        switch error {
        case let serviceError as UniMERNetServiceError:
            return serviceError.errorDescription ?? "Handwriting could not be read."
        case let recognitionError as HandwritingRecognitionError:
            return recognitionError.errorDescription ?? "Handwriting could not be read."
        case ExpressionEvaluationError.divisionByZero:
            return "Division by zero is not allowed."
        case is ExpressionEvaluationError:
            return "The expression could not be evaluated."
        default:
            return "The operation could not be completed."
        }
    }

    nonisolated private static func statusItemTitle(for text: String) -> String {
        let maxLength = 8
        guard text.count > maxLength else { return text }
        return "\(text.prefix(maxLength))…"
    }
}
