//
//  ExpressionSanitizer.swift
//  QuickCalc
//
//  Created by Codex on 11.04.2026.
//

import Foundation

struct ExpressionCandidate: Equatable, Sendable {
    let expression: String
    let score: Int
    let source: String
}

enum ExpressionSanitizer {
    nonisolated static func candidates(
        from rawText: String,
        baseScore: Int = 1_000,
        source: String = "ocr"
    ) -> [ExpressionCandidate] {
        let cleanedText = cleanedStructuralText(from: rawText)
        guard let result = buildCandidate(from: cleanedText) else {
            return []
        }

        let score = max(baseScore - result.penalty, 0)
        return [
            ExpressionCandidate(
                expression: result.expression,
                score: score,
                source: source
            )
        ]
    }

    nonisolated static func bestExpression(from rawText: String) -> String {
        candidates(from: rawText).first?.expression ?? ""
    }

    nonisolated static func uniqueCandidates(_ candidates: [ExpressionCandidate]) -> [ExpressionCandidate] {
        var bestByExpression: [String: ExpressionCandidate] = [:]

        for candidate in candidates {
            if let existing = bestByExpression[candidate.expression], existing.score >= candidate.score {
                continue
            }

            bestByExpression[candidate.expression] = candidate
        }

        return bestByExpression.values.sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }

            if $0.expression.count != $1.expression.count {
                return $0.expression.count < $1.expression.count
            }

            return $0.expression < $1.expression
        }
    }

    private struct BuildResult: Sendable {
        let expression: String
        let penalty: Int
    }

    private enum OutputContext {
        case start
        case openParen
        case operatorToken
        case valueToken

        nonisolated var canPrecedeUnaryOperator: Bool {
            switch self {
            case .start, .openParen, .operatorToken:
                return true
            case .valueToken:
                return false
            }
        }

        nonisolated var representsValue: Bool {
            switch self {
            case .valueToken:
                return true
            case .start, .openParen, .operatorToken:
                return false
            }
        }
    }

    nonisolated private static let multiplicationCharacters: Set<Character> = ["*", "×", "·", "⋅", "∙", "∗", "⨯"]
    nonisolated private static let divisionCharacters: Set<Character> = ["/", "÷", "∕", "⁄", ":"]
    nonisolated private static let minusCharacters: Set<Character> = ["-", "−", "–", "—", "﹣", "－"]
    nonisolated private static let plusCharacters: Set<Character> = ["+", "＋"]
    nonisolated private static let equalsCharacters: Set<Character> = ["=", "＝"]

    nonisolated private static func cleanedStructuralText(from rawText: String) -> String {
        expandFractions(in: rawText)
            .precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\\left", with: "")
            .replacingOccurrences(of: "\\right", with: "")
            .replacingOccurrences(of: "\\times", with: "*")
            .replacingOccurrences(of: "\\cdot", with: "*")
            .replacingOccurrences(of: "\\div", with: "/")
            .replacingOccurrences(of: "\\,", with: "")
            .replacingOccurrences(of: "\\!", with: "")
            .replacingOccurrences(of: "\\;", with: "")
            .replacingOccurrences(of: "\\:", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
    }

    nonisolated private static func buildCandidate(from text: String) -> BuildResult? {
        var index = text.startIndex
        var output = ""
        var penalty = 0
        var context = OutputContext.start
        var parenthesisDepth = 0

        while index < text.endIndex {
            let character = text[index]

            if character.isWhitespace || character == "\n" || character == "\t" {
                index = text.index(after: index)
                continue
            }

            if equalsCharacters.contains(character) {
                break
            }

            if let number = scanNumber(in: text, from: &index) {
                if context.representsValue {
                    output.append("*")
                    penalty += 2
                }

                output.append(number)
                context = .valueToken
                continue
            }

            if isOpenParenthesis(character) {
                if context.representsValue {
                    output.append("*")
                    penalty += 2
                }

                output.append("(")
                parenthesisDepth += 1
                context = .openParen
                index = text.index(after: index)
                continue
            }

            if isCloseParenthesis(character) {
                guard parenthesisDepth > 0, context.representsValue else {
                    return nil
                }

                output.append(")")
                parenthesisDepth -= 1
                context = .valueToken
                index = text.index(after: index)
                continue
            }

            if let `operator` = canonicalOperator(for: character) {
                switch `operator` {
                case "+", "-":
                    if context.canPrecedeUnaryOperator || context.representsValue {
                        output.append(`operator`)
                        context = .operatorToken
                        index = text.index(after: index)
                        continue
                    }
                default:
                    if context.representsValue {
                        output.append(`operator`)
                        context = .operatorToken
                        index = text.index(after: index)
                        continue
                    }
                }

                return nil
            }

            return nil
        }

        guard output.isEmpty == false, parenthesisDepth == 0, context.representsValue else {
            return nil
        }

        guard (try? ExpressionEvaluator.evaluate(output)) != nil else {
            return nil
        }

        return BuildResult(expression: output, penalty: penalty)
    }

    nonisolated private static func scanNumber(in text: String, from index: inout String.Index) -> String? {
        var cursor = index
        var digits = ""
        var sawDigit = false
        var sawDecimalSeparator = false

        if cursor < text.endIndex,
           isDecimalSeparator(text[cursor]),
           let nextCharacter = nextSignificantCharacter(in: text, after: cursor),
           nextCharacter.isNumber {
            digits = "0."
            sawDecimalSeparator = true
            cursor = text.index(after: cursor)
        }

        while cursor < text.endIndex {
            let character = text[cursor]

            if character.isNumber {
                sawDigit = true
                digits.append(character)
                cursor = text.index(after: cursor)
                continue
            }

            if isDecimalSeparator(character),
               sawDecimalSeparator == false,
               let nextCharacter = nextSignificantCharacter(in: text, after: cursor),
               nextCharacter.isNumber,
               sawDigit {
                sawDecimalSeparator = true
                digits.append(".")
                cursor = text.index(after: cursor)
                continue
            }

            if character.isWhitespace,
               sawDigit,
               let nextIndex = nextSignificantIndex(in: text, after: cursor) {
                let nextCharacter = text[nextIndex]

                if nextCharacter.isNumber {
                    cursor = nextIndex
                    continue
                }

                if isDecimalSeparator(nextCharacter),
                   sawDecimalSeparator == false,
                   let nextAfterSeparator = nextSignificantCharacter(in: text, after: nextIndex),
                   nextAfterSeparator.isNumber {
                    cursor = nextIndex
                    continue
                }
            }

            break
        }

        guard sawDigit else {
            return nil
        }

        index = cursor
        return digits
    }

    nonisolated private static func nextSignificantIndex(in text: String, after index: String.Index) -> String.Index? {
        var cursor = text.index(after: index)

        while cursor < text.endIndex {
            if text[cursor].isWhitespace == false {
                return cursor
            }
            cursor = text.index(after: cursor)
        }

        return nil
    }

    nonisolated private static func nextSignificantCharacter(in text: String, after index: String.Index) -> Character? {
        guard let nextIndex = nextSignificantIndex(in: text, after: index) else {
            return nil
        }

        return text[nextIndex]
    }

    nonisolated private static func canonicalOperator(for character: Character) -> String? {
        if plusCharacters.contains(character) {
            return "+"
        }

        if minusCharacters.contains(character) {
            return "-"
        }

        if multiplicationCharacters.contains(character) {
            return "*"
        }

        if divisionCharacters.contains(character) {
            return "/"
        }

        return nil
    }

    nonisolated private static func isOpenParenthesis(_ character: Character) -> Bool {
        ["(", "[", "{"].contains(character)
    }

    nonisolated private static func isCloseParenthesis(_ character: Character) -> Bool {
        [")", "]", "}"].contains(character)
    }

    nonisolated private static func isDecimalSeparator(_ character: Character) -> Bool {
        character == "." || character == ","
    }

    nonisolated private static func expandFractions(in text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\\frac\s*\{([^{}]+)\}\s*\{([^{}]+)\}"#,
            options: []
        ) else {
            return text
        }

        var expanded = text

        while true {
            let fullRange = NSRange(expanded.startIndex..<expanded.endIndex, in: expanded)
            guard let match = regex.firstMatch(in: expanded, options: [], range: fullRange),
                  let numeratorRange = Range(match.range(at: 1), in: expanded),
                  let denominatorRange = Range(match.range(at: 2), in: expanded),
                  let matchRange = Range(match.range(at: 0), in: expanded) else {
                break
            }

            let numerator = String(expanded[numeratorRange])
            let denominator = String(expanded[denominatorRange])
            expanded.replaceSubrange(matchRange, with: "(\(numerator))/(\(denominator))")
        }

        return expanded
    }
}
