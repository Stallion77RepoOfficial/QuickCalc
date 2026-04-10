//
//  VisionExpressionRecognizer.swift
//  QuickCalc
//
//  Created by Codex on 11.04.2026.
//

import CoreGraphics
import Foundation
import Vision

struct VisionExpressionRecognizer {
    func recognizeCandidates(from images: [CGImage]) async -> [ExpressionCandidate] {
        var allCandidates: [ExpressionCandidate] = []

        for (index, image) in images.enumerated() {
            let candidates = await recognizeCandidates(from: image, imageIndex: index)
            allCandidates.append(contentsOf: candidates)
        }

        return ExpressionSanitizer.uniqueCandidates(allCandidates)
    }

    private func recognizeCandidates(from image: CGImage, imageIndex: Int) async -> [ExpressionCandidate] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.recognitionLanguages = ["en-US"]

                do {
                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([request])

                    let observations = (request.results ?? []).sorted(by: Self.readingOrder)
                    var candidates: [ExpressionCandidate] = []

                    let combined = observations
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined()

                    if combined.isEmpty == false {
                        candidates.append(
                            contentsOf: ExpressionSanitizer.candidates(
                                from: combined,
                                baseScore: 700 - (imageIndex * 20),
                                source: "vision-combined"
                            )
                        )
                    }

                    for (observationIndex, observation) in observations.enumerated() {
                        for (candidateIndex, textCandidate) in observation.topCandidates(2).enumerated() {
                            let baseScore = Int(textCandidate.confidence * 1_000)
                                - (imageIndex * 20)
                                - (observationIndex * 10)
                                - candidateIndex

                            candidates.append(
                                contentsOf: ExpressionSanitizer.candidates(
                                    from: textCandidate.string,
                                    baseScore: baseScore,
                                    source: "vision"
                                )
                            )
                        }
                    }

                    continuation.resume(returning: ExpressionSanitizer.uniqueCandidates(candidates))
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    nonisolated private static func readingOrder(
        lhs: VNRecognizedTextObservation,
        rhs: VNRecognizedTextObservation
    ) -> Bool {
        if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.04 {
            return lhs.boundingBox.midY > rhs.boundingBox.midY
        }

        return lhs.boundingBox.minX < rhs.boundingBox.minX
    }
}
