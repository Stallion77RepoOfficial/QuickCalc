//
//  AppDelegate.swift
//  QuickCalc
//
//  Created by Codex on 7.04.2026.
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appModel = AppModel()
    private var statusBarController: StatusBarController?
    private var drawingPanelController: DrawingPanelController?
    private var clickMonitor: GlobalClickMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusBarController = StatusBarController(model: appModel)
        drawingPanelController = DrawingPanelController(model: appModel)
        clickMonitor = GlobalClickMonitor { [weak self] in
            self?.openCanvas()
        }

        appModel.showPopoverAction = { [weak self] in
            self?.statusBarController?.showPopover()
        }
        appModel.closeCanvasAction = { [weak self] in
            self?.drawingPanelController?.close()
        }

        clickMonitor?.start()
        Task {
            await UniMERNetService.shared.prewarm()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clickMonitor?.stop()
    }

    private func openCanvas() {
        guard let drawingPanelController else { return }
        NSApp.activate(ignoringOtherApps: true)
        drawingPanelController.show()
    }
}
