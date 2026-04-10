//
//  TrackpadCanvasView.swift
//  QuickCalc
//
//  Created by Codex on 7.04.2026.
//

import AppKit
import SwiftUI

struct TrackpadCanvasView: NSViewRepresentable {
    @ObservedObject var controller: CanvasController
    let onIdle: ([Stroke], CGSize) -> Void

    func makeNSView(context: Context) -> TrackpadCanvasNSView {
        let view = TrackpadCanvasNSView()
        controller.attach(view)

        view.onIdle = { strokes, size in
            onIdle(strokes, size)
        }

        return view
    }

    func updateNSView(_ nsView: TrackpadCanvasNSView, context: Context) {
        controller.attach(nsView)
        nsView.isRecognizing = controller.isRecognizing
    }
}

@MainActor
final class TrackpadCanvasNSView: NSView {
    private static let idleDelay: TimeInterval = 2.5

    var onIdle: (([Stroke], CGSize) -> Void)?

    var isRecognizing = false {
        didSet {
            needsDisplay = true
        }
    }

    private var cursorSession = CursorStrokeSession()
    private var idleWorkItem: DispatchWorkItem?
    private var hasActiveTouches = false
    private var isPointerPressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsRestingTouches = false
        allowedTouchTypes = [.indirect]
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focus()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.02, alpha: 0.035).setFill()
        dirtyRect.fill()

        drawStrokes()
        drawOverlayIfNeeded()
    }

    override func touchesBegan(with event: NSEvent) {
        guard !isRecognizing else { return }
        refreshTouchState(from: event)
        beginDrawingIfNeeded(timestamp: event.timestamp)
    }

    override func touchesMoved(with event: NSEvent) {
        guard !isRecognizing else { return }
        refreshTouchState(from: event)
        appendDrawingIfNeeded(timestamp: event.timestamp)
    }

    override func touchesEnded(with event: NSEvent) {
        guard !isRecognizing else { return }
        refreshTouchState(from: event)
        endDrawingIfNeeded(timestamp: event.timestamp)
    }

    override func touchesCancelled(with event: NSEvent) {
        guard !isRecognizing else { return }
        refreshTouchState(from: event)
        endDrawingIfNeeded(timestamp: event.timestamp)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isRecognizing else { return }
        isPointerPressed = true
        beginDrawingIfNeeded(timestamp: event.timestamp)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isRecognizing else { return }
        appendDrawingIfNeeded(timestamp: event.timestamp)
    }

    override func mouseUp(with event: NSEvent) {
        guard !isRecognizing else { return }
        isPointerPressed = false
        finishDrawing(timestamp: event.timestamp)
    }

    func clear() {
        idleWorkItem?.cancel()
        cursorSession.clear()
        hasActiveTouches = false
        isPointerPressed = false
        needsDisplay = true
    }

    func focus() {
        window?.makeFirstResponder(self)
    }

    private func refreshTouchState(from event: NSEvent) {
        hasActiveTouches = !event.touches(matching: .touching, in: self).isEmpty
    }

    private var isDrawingAllowed: Bool {
        isPointerPressed && hasActiveTouches
    }

    private func beginDrawingIfNeeded(timestamp: TimeInterval) {
        guard isDrawingAllowed else { return }
        idleWorkItem?.cancel()
        _ = cursorSession.begin(at: cursorPointInView(), timestamp: timestamp)
        needsDisplay = true
    }

    private func appendDrawingIfNeeded(timestamp: TimeInterval) {
        guard isDrawingAllowed else {
            endDrawingIfNeeded(timestamp: timestamp)
            return
        }

        idleWorkItem?.cancel()

        let didChange = cursorSession.isDrawing
            ? cursorSession.append(at: cursorPointInView(), timestamp: timestamp)
            : cursorSession.begin(at: cursorPointInView(), timestamp: timestamp)

        if didChange {
            needsDisplay = true
        }
    }

    private func endDrawingIfNeeded(timestamp: TimeInterval) {
        guard cursorSession.isDrawing, !isDrawingAllowed else { return }
        finishDrawing(timestamp: timestamp)
    }

    private func finishDrawing(timestamp: TimeInterval) {
        guard cursorSession.isDrawing else { return }

        _ = cursorSession.append(at: cursorPointInView(), timestamp: timestamp)
        cursorSession.end()
        scheduleIdleTimer()
        needsDisplay = true
    }

    private func scheduleIdleTimer() {
        idleWorkItem?.cancel()

        let snapshot = cursorSession.strokes
        guard !snapshot.isEmpty else { return }

        let size = bounds.size
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isRecognizing else { return }
            self.onIdle?(snapshot, size)
        }

        idleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleDelay, execute: workItem)
    }

    private func cursorPointInView() -> CGPoint? {
        guard let window else { return nil }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = convert(windowPoint, from: nil)

        guard bounds.contains(localPoint) else { return nil }
        return localPoint
    }

    private func drawStrokes() {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = 10
        NSColor(calibratedRed: 0.23, green: 0.85, blue: 1, alpha: 0.96).setStroke()

        for stroke in cursorSession.strokes where !stroke.points.isEmpty {
            guard let first = stroke.points.first else { continue }

            if stroke.points.count == 1 {
                let dotRect = CGRect(x: first.location.x - 5, y: first.location.y - 5, width: 10, height: 10)
                NSBezierPath(ovalIn: dotRect).fill()
                continue
            }

            path.move(to: first.location)

            for point in stroke.points.dropFirst() {
                path.line(to: point.location)
            }
        }

        path.stroke()
    }

    private func drawOverlayIfNeeded() {
        guard isRecognizing else { return }

        NSColor(calibratedWhite: 0.04, alpha: 0.22).setFill()
        bounds.fill(using: .sourceAtop)
    }
}
