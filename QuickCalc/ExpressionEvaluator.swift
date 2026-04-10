//
//  ExpressionEvaluator.swift
//  QuickCalc
//
//  Created by Codex on 7.04.2026.
//

import Foundation

enum ExpressionEvaluationError: LocalizedError, Equatable {
    case expectedNumber
    case expectedClosingParenthesis
    case invalidCharacter(Character)
    case divisionByZero

    var errorDescription: String? {
        switch self {
        case .expectedNumber:
            return "A number was expected."
        case .expectedClosingParenthesis:
            return "A closing parenthesis is missing."
        case .invalidCharacter(let character):
            return "Unsupported character: \(character)"
        case .divisionByZero:
            return "Division by zero is not allowed."
        }
    }
}

struct ExpressionEvaluator {
    nonisolated static func evaluate(_ input: String) throws -> Double {
        var parser = Parser(text: input)
        return try parser.parse()
    }

    nonisolated static func format(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.000_000_1 {
            return String(Int(rounded))
        }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 8
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

private struct Parser {
    let text: String
    var index: String.Index

    nonisolated init(text: String) {
        self.text = text
        self.index = text.startIndex
    }

    nonisolated mutating func parse() throws -> Double {
        let value = try parseExpression()
        skipWhitespace()

        guard index == text.endIndex else {
            throw ExpressionEvaluationError.invalidCharacter(text[index])
        }

        return value
    }

    nonisolated private mutating func parseExpression() throws -> Double {
        var value = try parseTerm()

        while true {
            skipWhitespace()

            if match("+") {
                value += try parseTerm()
            } else if match("-") {
                value -= try parseTerm()
            } else {
                return value
            }
        }
    }

    nonisolated private mutating func parseTerm() throws -> Double {
        var value = try parseFactor()

        while true {
            skipWhitespace()

            if match("*") {
                value *= try parseFactor()
            } else if match("/") {
                let divisor = try parseFactor()
                guard abs(divisor) > 0.000_000_1 else {
                    throw ExpressionEvaluationError.divisionByZero
                }
                value /= divisor
            } else {
                return value
            }
        }
    }

    nonisolated private mutating func parseFactor() throws -> Double {
        skipWhitespace()

        if match("+") {
            return try parseFactor()
        }

        if match("-") {
            return -(try parseFactor())
        }

        if match("(") {
            let value = try parseExpression()
            skipWhitespace()

            guard match(")") else {
                throw ExpressionEvaluationError.expectedClosingParenthesis
            }

            return value
        }

        return try parseNumber()
    }

    nonisolated private mutating func parseNumber() throws -> Double {
        skipWhitespace()
        let start = index
        var sawDigit = false
        var sawDecimalSeparator = false

        while index < text.endIndex {
            let character = text[index]

            if character.isNumber {
                sawDigit = true
                advance()
            } else if character == "." && !sawDecimalSeparator {
                sawDecimalSeparator = true
                advance()
            } else {
                break
            }
        }

        guard sawDigit else {
            throw ExpressionEvaluationError.expectedNumber
        }

        let numberText = String(text[start..<index])
        guard let value = Double(numberText) else {
            throw ExpressionEvaluationError.expectedNumber
        }

        return value
    }

    nonisolated private mutating func match(_ character: Character) -> Bool {
        guard index < text.endIndex, text[index] == character else {
            return false
        }

        advance()
        return true
    }

    nonisolated private mutating func skipWhitespace() {
        while index < text.endIndex, text[index].isWhitespace {
            advance()
        }
    }

    nonisolated private mutating func advance() {
        index = text.index(after: index)
    }
}
