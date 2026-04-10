//
//  HandwritingRecognizer.swift
//  QuickCalc
//
//  Created by Codex on 7.04.2026.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum HandwritingRecognitionError: LocalizedError {
    case emptyDrawing
    case couldNotRenderImage
    case noTextFound

    var errorDescription: String? {
        switch self {
        case .emptyDrawing:
            return "No drawing was detected."
        case .couldNotRenderImage:
            return "The drawing could not be rendered."
        case .noTextFound:
            return "Handwriting could not be read."
        }
    }
}

struct HandwritingRecognizer {
    func recognizeExpression(from strokes: [Stroke], canvasSize: CGSize) async throws -> String {
        let normalizedStrokes = Self.normalizedStrokesForRecognition(strokes)
        guard normalizedStrokes.flatMap(\.points).isEmpty == false else {
            throw HandwritingRecognitionError.emptyDrawing
        }

        let candidates = try await Self.recognitionCandidates(from: normalizedStrokes, canvasSize: canvasSize)

        if let candidate = candidates.first {
            return candidate.expression
        }

        throw HandwritingRecognitionError.noTextFound
    }

    nonisolated static func normalizedStrokesForRecognition(_ strokes: [Stroke]) -> [Stroke] {
        flattenWritingAngle(in: strokes)
    }

    nonisolated static func normalizedUniMERNetOutputForTesting(_ text: String) -> String {
        ExpressionSanitizer.bestExpression(from: text)
    }

    private static func recognitionCandidates(from strokes: [Stroke], canvasSize: CGSize) async throws -> [ExpressionCandidate] {
        let images = try makeImages(from: strokes, canvasSize: canvasSize)
        var allCandidates: [ExpressionCandidate] = []
        var modelError: Error?

        do {
            allCandidates.append(contentsOf: try await uniMERNetCandidates(from: images))
        } catch {
            modelError = error
        }

        if allCandidates.isEmpty {
            let visionCandidates = await VisionExpressionRecognizer().recognizeCandidates(from: images)
            allCandidates.append(contentsOf: visionCandidates)
        }

        let unique = ExpressionSanitizer.uniqueCandidates(allCandidates)
        if unique.isEmpty == false {
            return unique
        }

        if let modelError {
            throw modelError
        }

        throw HandwritingRecognitionError.noTextFound
    }

    private static func uniMERNetCandidates(from images: [CGImage]) async throws -> [ExpressionCandidate] {
        var candidates: [ExpressionCandidate] = []
        var firstError: Error?

        for (index, image) in images.enumerated() {
            do {
                let rawOutput = try await recognizeWithUniMERNet(image)
                candidates.append(
                    contentsOf: ExpressionSanitizer.candidates(
                        from: rawOutput,
                        baseScore: 1_000 - (index * 25),
                        source: "unimernet"
                    )
                )
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        let unique = ExpressionSanitizer.uniqueCandidates(candidates)
        if unique.isEmpty == false {
            return unique
        }

        if let firstError {
            throw firstError
        }

        throw HandwritingRecognitionError.noTextFound
    }

    private static func recognizeWithUniMERNet(_ image: CGImage) async throws -> String {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickcalc-unimernet-\(UUID().uuidString)")
            .appendingPathExtension("png")

        try writePNG(image, to: temporaryURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        return try await UniMERNetService.shared.recognize(imageURL: temporaryURL)
    }

    nonisolated private static func makeImages(from strokes: [Stroke], canvasSize: CGSize) throws -> [CGImage] {
        let allPoints = strokes.flatMap(\.points)
        guard allPoints.isEmpty == false else {
            throw HandwritingRecognitionError.emptyDrawing
        }

        let rawBounds = allPoints.reduce(into: CGRect.null) { partialResult, point in
            partialResult = partialResult.union(CGRect(origin: point.location, size: .zero))
        }

        guard rawBounds.isNull == false else {
            throw HandwritingRecognitionError.emptyDrawing
        }

        let fallbackSize = canvasSize == .zero ? CGSize(width: 900, height: 420) : canvasSize
        let safeBounds = rawBounds.insetBy(dx: -22, dy: -22)
        let renderBounds = safeBounds.isNull ? CGRect(origin: .zero, size: fallbackSize) : safeBounds

        return try RenderConfiguration.all.map { configuration in
            try makeImage(from: strokes, safeBounds: renderBounds, configuration: configuration)
        }
    }

    nonisolated private static func makeImage(
        from strokes: [Stroke],
        safeBounds: CGRect,
        configuration: RenderConfiguration
    ) throws -> CGImage {
        let aspectRatio = max(safeBounds.width / max(safeBounds.height, 1), 0.8)
        let renderWidth = configuration.renderWidth
        let renderHeight = max(
            Int(CGFloat(renderWidth) / min(aspectRatio, configuration.maximumAspectRatio)),
            configuration.minimumHeight
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: renderWidth,
            height: renderHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw HandwritingRecognitionError.couldNotRenderImage
        }

        let inset = configuration.padding
        let renderRect = CGRect(
            x: inset,
            y: inset,
            width: CGFloat(renderWidth) - (inset * 2),
            height: CGFloat(renderHeight) - (inset * 2)
        )
        let scale = min(
            renderRect.width / max(safeBounds.width, 1),
            renderRect.height / max(safeBounds.height, 1)
        )
        let xOffset = renderRect.midX - (safeBounds.midX * scale)
        let yOffset = renderRect.midY - (safeBounds.midY * scale)

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight))
        context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        for stroke in strokes where stroke.points.isEmpty == false {
            let transformedPoints = stroke.points.map { point in
                recognitionRenderPoint(
                    from: point.location,
                    scale: scale,
                    xOffset: xOffset,
                    yOffset: yOffset,
                    renderHeight: CGFloat(renderHeight)
                )
            }

            let lineWidth = max(configuration.minimumLineWidth, configuration.lineWidthMultiplier * scale)
            context.setLineWidth(lineWidth)

            if transformedPoints.count == 1, let point = transformedPoints.first {
                context.fillEllipse(
                    in: CGRect(
                        x: point.x - (lineWidth / 2),
                        y: point.y - (lineWidth / 2),
                        width: lineWidth,
                        height: lineWidth
                    )
                )
                continue
            }

            context.beginPath()
            context.addLines(between: transformedPoints)
            context.strokePath()
        }

        guard let image = context.makeImage() else {
            throw HandwritingRecognitionError.couldNotRenderImage
        }

        return image
    }

    nonisolated static func recognitionRenderPoint(
        from location: CGPoint,
        scale: CGFloat,
        xOffset: CGFloat,
        yOffset: CGFloat,
        renderHeight: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: (location.x * scale) + xOffset,
            y: renderHeight - ((location.y * scale) + yOffset)
        )
    }

    nonisolated private static func flattenWritingAngle(in strokes: [Stroke]) -> [Stroke] {
        let anchors = strokes.compactMap(strokeAnchor(for:))
        guard anchors.count >= 2 else { return strokes }

        let meanX = anchors.map(\.x).reduce(0, +) / CGFloat(anchors.count)
        let meanY = anchors.map(\.y).reduce(0, +) / CGFloat(anchors.count)
        let minX = anchors.map(\.x).min() ?? meanX
        let maxX = anchors.map(\.x).max() ?? meanX
        let spanX = maxX - minX
        guard spanX > 80 else { return strokes }

        let varianceX = anchors.reduce(CGFloat.zero) { partialResult, anchor in
            let deltaX = anchor.x - meanX
            return partialResult + (deltaX * deltaX)
        }
        guard varianceX > 1 else { return strokes }

        let covariance = anchors.reduce(CGFloat.zero) { partialResult, anchor in
            partialResult + ((anchor.x - meanX) * (anchor.y - meanY))
        }

        let slope = covariance / varianceX
        let angle = atan(Double(slope))
        guard abs(angle) > 0.08 else { return strokes }

        let clampedAngle = max(min(angle, 0.52), -0.52)
        let pivot = CGPoint(x: meanX, y: meanY)
        return rotate(strokes, around: pivot, by: -clampedAngle)
    }

    nonisolated private static func strokeAnchor(for stroke: Stroke) -> CGPoint? {
        guard stroke.points.isEmpty == false else { return nil }

        let count = CGFloat(stroke.points.count)
        let sum = stroke.points.reduce(CGPoint.zero) { partialResult, point in
            CGPoint(
                x: partialResult.x + point.location.x,
                y: partialResult.y + point.location.y
            )
        }

        return CGPoint(x: sum.x / count, y: sum.y / count)
    }

    nonisolated private static func rotate(_ strokes: [Stroke], around pivot: CGPoint, by angle: Double) -> [Stroke] {
        let cosAngle = CGFloat(cos(angle))
        let sinAngle = CGFloat(sin(angle))

        return strokes.map { stroke in
            Stroke(
                id: stroke.id,
                points: stroke.points.map { point in
                    let translatedX = point.location.x - pivot.x
                    let translatedY = point.location.y - pivot.y
                    let rotatedPoint = CGPoint(
                        x: (translatedX * cosAngle) - (translatedY * sinAngle) + pivot.x,
                        y: (translatedX * sinAngle) + (translatedY * cosAngle) + pivot.y
                    )

                    return StrokePoint(location: rotatedPoint, timestamp: point.timestamp)
                }
            )
        }
    }

    nonisolated private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw HandwritingRecognitionError.couldNotRenderImage
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw HandwritingRecognitionError.couldNotRenderImage
        }
    }

}

private struct RenderConfiguration: Sendable {
    let renderWidth: Int
    let minimumHeight: Int
    let padding: CGFloat
    let lineWidthMultiplier: CGFloat
    let minimumLineWidth: CGFloat
    let maximumAspectRatio: CGFloat

    nonisolated static let all: [RenderConfiguration] = [
        RenderConfiguration(
            renderWidth: 2200,
            minimumHeight: 560,
            padding: 64,
            lineWidthMultiplier: 12,
            minimumLineWidth: 18,
            maximumAspectRatio: 6.4
        ),
        RenderConfiguration(
            renderWidth: 1800,
            minimumHeight: 520,
            padding: 48,
            lineWidthMultiplier: 10,
            minimumLineWidth: 16,
            maximumAspectRatio: 5.4
        ),
        RenderConfiguration(
            renderWidth: 1500,
            minimumHeight: 500,
            padding: 72,
            lineWidthMultiplier: 14,
            minimumLineWidth: 20,
            maximumAspectRatio: 4.6
        ),
        RenderConfiguration(
            renderWidth: 1200,
            minimumHeight: 420,
            padding: 28,
            lineWidthMultiplier: 8,
            minimumLineWidth: 12,
            maximumAspectRatio: 8.5
        )
    ]
}
