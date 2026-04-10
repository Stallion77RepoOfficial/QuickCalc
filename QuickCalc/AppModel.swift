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
    struct StatusPresentation: Equatable {
        enum Content: Equatable {
            case empty
            case loading
            case error(String)
            case result(expression: String, value: String)
        }

        let menuBarTitle: String
        let lastExpression: String
        let lastResult: String
        let errorMessage: String?
        let isProcessing: Bool

        var content: Content {
            if let errorMessage, !errorMessage.isEmpty {
                return .error(errorMessage)
            }

            if !lastResult.isEmpty {
                return .result(expression: lastExpression, value: lastResult)
            }

            if isProcessing {
                return .loading
            }

            return .empty
        }
    }

    @Published private(set) var statusPresentation = StatusPresentation(
        menuBarTitle: "",
        lastExpression: "",
        lastResult: "",
        errorMessage: nil,
        isProcessing: false
    )

    var showPopoverAction: (() -> Void)?
    var closeCanvasAction: (() -> Void)?

    private let recognizer = HandwritingRecognizer()

    func processDrawing(strokes: [Stroke], canvasSize: CGSize) async {
        guard statusPresentation.isProcessing == false else { return }
        applyStatus(
            menuBarTitle: "...",
            lastExpression: "",
            lastResult: "",
            errorMessage: nil,
            isProcessing: true
        )

        var resolvedExpression = ""

        do {
            let expression = try await recognizer.recognizeExpression(from: strokes, canvasSize: canvasSize)
            resolvedExpression = expression

            let value = try ExpressionEvaluator.evaluate(expression)
            let formatted = ExpressionEvaluator.format(value)

            applyStatus(
                menuBarTitle: Self.statusItemTitle(for: formatted),
                lastExpression: expression,
                lastResult: formatted,
                errorMessage: nil,
                isProcessing: false
            )
        } catch {
            applyStatus(
                menuBarTitle: "!",
                lastExpression: resolvedExpression,
                lastResult: "",
                errorMessage: Self.userFacingMessage(for: error),
                isProcessing: false
            )
        }

        closeCanvasAction?()
        DispatchQueue.main.async { [weak self] in
            self?.showPopoverAction?()
        }
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

    private func applyStatus(
        menuBarTitle: String,
        lastExpression: String,
        lastResult: String,
        errorMessage: String?,
        isProcessing: Bool
    ) {
        statusPresentation = StatusPresentation(
            menuBarTitle: menuBarTitle,
            lastExpression: lastExpression,
            lastResult: lastResult,
            errorMessage: errorMessage,
            isProcessing: isProcessing
        )
    }
}
