//
//  Stroke.swift
//  QuickCalc
//
//  Created by Codex on 7.04.2026.
//

import CoreGraphics
import Foundation

struct StrokePoint: Sendable {
    let location: CGPoint
    let timestamp: TimeInterval
}

struct Stroke: Identifiable, Sendable {
    let id: UUID
    var points: [StrokePoint]

    nonisolated init(id: UUID = UUID(), points: [StrokePoint] = []) {
        self.id = id
        self.points = points
    }
}
