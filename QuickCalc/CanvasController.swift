//
//  CanvasController.swift
//  QuickCalc
//
//  Created by Codex on 7.04.2026.
//

import Combine
import Foundation

@MainActor
final class CanvasController: ObservableObject {
    @Published var isRecognizing = false

    weak var canvasView: TrackpadCanvasNSView?

    func attach(_ view: TrackpadCanvasNSView) {
        canvasView = view
    }

    func clear() {
        isRecognizing = false
        canvasView?.clear()
    }

    func focusCanvas() {
        canvasView?.focus()
    }
}
