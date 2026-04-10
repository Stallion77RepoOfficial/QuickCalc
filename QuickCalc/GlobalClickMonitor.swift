//
//  GlobalClickMonitor.swift
//  QuickCalc
//
//  Created by Codex on 7.04.2026.
//

import AppKit

final class GlobalClickMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private let handler: () -> Void
    private var clickStreak = 0
    private var lastClickTimestamp: TimeInterval = 0
    private var lastClickLocation = CGPoint.zero

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handle(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        let clickLocation = NSEvent.mouseLocation
        let isNearLastClick = hypot(clickLocation.x - lastClickLocation.x, clickLocation.y - lastClickLocation.y) < 44
        let isRapid = (event.timestamp - lastClickTimestamp) < 0.6

        if event.clickCount >= 3 {
            reset()
            handler()
            return
        }

        if isNearLastClick && isRapid {
            clickStreak += 1
        } else {
            clickStreak = 1
        }

        lastClickTimestamp = event.timestamp
        lastClickLocation = clickLocation

        if clickStreak >= 3 {
            reset()
            handler()
        }
    }

    private func reset() {
        clickStreak = 0
        lastClickTimestamp = 0
        lastClickLocation = .zero
    }
}
