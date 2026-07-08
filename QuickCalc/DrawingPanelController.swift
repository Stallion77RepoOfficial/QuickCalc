//
//  DrawingPanelController.swift
//  QuickCalc
//
//  Created by Codex on 7.04.2026.
//

import AppKit
import SwiftUI

@MainActor
final class DrawingPanelController {
    private let model: AppModel
    private let canvasController = CanvasController()
    private lazy var panel: DrawingPanel = makePanel()
    private var drawingGeneration = 0

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        drawingGeneration += 1
        canvasController.clear()
        panel.setFrame(panelFrame(), display: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async { [weak self] in
            self?.canvasController.focusCanvas()
        }
    }

    func close() {
        drawingGeneration += 1
        panel.orderOut(nil)
        canvasController.clear()
    }

    private func makePanel() -> DrawingPanel {
        let panel = DrawingPanel(
            contentRect: panelFrame(),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow

        let rootView = DrawingPanelView(
            canvasController: canvasController,
            onIdle: { [weak self] strokes, canvasSize in
                guard let self else { return }
                let generation = self.drawingGeneration
                self.canvasController.isRecognizing = true

                Task { [weak self] in
                    guard let self else { return }
                    await self.model.processDrawing(strokes: strokes, canvasSize: canvasSize)
                    await MainActor.run {
                        if self.drawingGeneration == generation {
                            self.canvasController.isRecognizing = false
                        }
                    }
                }
            },
            onClose: { [weak self] in
                self?.close()
            }
        )

        panel.contentViewController = NSHostingController(rootView: rootView)
        return panel
    }

    private func panelFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first

        return screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

final class DrawingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
