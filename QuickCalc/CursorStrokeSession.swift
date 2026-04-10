//
//  CursorStrokeSession.swift
//  QuickCalc
//
//  Created by Codex on 10.04.2026.
//

import CoreGraphics
import Foundation

struct CursorStrokeSession {
    private let minimumSampleDistance: CGFloat
    private let interpolationStep: CGFloat

    private(set) var strokes: [Stroke] = []
    private(set) var isDrawing = false
    private var currentStrokeIndex: Int?

    init(
        minimumSampleDistance: CGFloat = 1.5,
        interpolationStep: CGFloat = 18
    ) {
        self.minimumSampleDistance = minimumSampleDistance
        self.interpolationStep = interpolationStep
    }

    mutating func clear() {
        strokes.removeAll()
        isDrawing = false
        currentStrokeIndex = nil
    }

    @discardableResult
    mutating func begin(at point: CGPoint?, timestamp: TimeInterval) -> Bool {
        guard !isDrawing else {
            return append(at: point, timestamp: timestamp)
        }

        isDrawing = true
        currentStrokeIndex = nil
        return appendSampleIfPossible(at: point, timestamp: timestamp)
    }

    @discardableResult
    mutating func append(at point: CGPoint?, timestamp: TimeInterval) -> Bool {
        guard isDrawing else { return false }
        return appendSampleIfPossible(at: point, timestamp: timestamp)
    }

    mutating func end() {
        isDrawing = false
        currentStrokeIndex = nil
    }

    private mutating func appendSampleIfPossible(at point: CGPoint?, timestamp: TimeInterval) -> Bool {
        guard let point else { return false }

        let sample = StrokePoint(location: point, timestamp: timestamp)

        guard let strokeIndex = currentStrokeIndex, strokes.indices.contains(strokeIndex) else {
            strokes.append(Stroke(points: [sample]))
            currentStrokeIndex = strokes.count - 1
            return true
        }

        guard let lastPoint = strokes[strokeIndex].points.last else {
            strokes[strokeIndex].points.append(sample)
            return true
        }

        let distance = hypot(
            sample.location.x - lastPoint.location.x,
            sample.location.y - lastPoint.location.y
        )
        guard distance > minimumSampleDistance else { return false }

        if interpolationStep > 0 {
            for traveledDistance in stride(from: interpolationStep, to: distance, by: interpolationStep) {
                let progress = traveledDistance / distance

                strokes[strokeIndex].points.append(
                    StrokePoint(
                        location: CGPoint(
                            x: lastPoint.location.x + ((sample.location.x - lastPoint.location.x) * progress),
                            y: lastPoint.location.y + ((sample.location.y - lastPoint.location.y) * progress)
                        ),
                        timestamp: lastPoint.timestamp + ((sample.timestamp - lastPoint.timestamp) * TimeInterval(progress))
                    )
                )
            }
        }

        strokes[strokeIndex].points.append(sample)
        return true
    }
}
