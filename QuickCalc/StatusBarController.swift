//
//  StatusBarController.swift
//  QuickCalc
//
//  Created by Codex on 7.04.2026.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private lazy var hostingController = NSHostingController(rootView: popoverRootView(for: model.statusPresentation))
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        configureStatusItem()
        configurePopover()
        bindModel()
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        hostingController.rootView = popoverRootView(for: model.statusPresentation)
        popover.contentSize = popoverSize(for: model.statusPresentation)

        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.image = NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: "QuickCalc")
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePopover)
        button.toolTip = "QuickCalc"
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = popoverSize(for: model.statusPresentation)
        popover.contentViewController = hostingController
    }

    private func bindModel() {
        model.$statusPresentation
            .sink { [weak self] presentation in
                self?.updateButton(using: presentation)
                self?.popover.contentSize = self?.popoverSize(for: presentation) ?? NSSize(width: 240, height: 120)
                self?.hostingController.rootView = self?.popoverRootView(for: presentation)
                    ?? StatusPopoverView(presentation: presentation, onClose: {})
            }
            .store(in: &cancellables)
    }

    private func popoverRootView(for presentation: AppModel.StatusPresentation) -> StatusPopoverView {
        StatusPopoverView(presentation: presentation) { [weak self] in
            self?.popover.performClose(nil)
        }
    }

    private func updateButton(using presentation: AppModel.StatusPresentation) {
        guard let button = statusItem.button else { return }

        button.title = presentation.menuBarTitle.isEmpty ? "" : " \(presentation.menuBarTitle)"
        button.imagePosition = presentation.menuBarTitle.isEmpty ? .imageOnly : .imageLeading

        switch presentation.content {
        case .loading:
            button.image = NSImage(systemSymbolName: "hourglass.circle", accessibilityDescription: "QuickCalc processing")
            button.toolTip = "Processing"
        case let .error(errorMessage):
            button.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "QuickCalc error")
            button.toolTip = errorMessage
        case let .result(expression, value):
            button.image = NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: "QuickCalc")
            button.toolTip = expression.isEmpty ? value : "\(expression) = \(value)"
        case .empty:
            button.image = NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: "QuickCalc")
            button.toolTip = "QuickCalc"
        }
    }

    private func popoverSize(for presentation: AppModel.StatusPresentation) -> NSSize {
        let width = popoverWidth(for: presentation)

        let contentHeight: CGFloat
        switch presentation.content {
        case .loading, .empty:
            contentHeight = 78
        case let .error(errorMessage):
            let textHeight = measuredHeight(
                of: errorMessage,
                width: width - 32,
                font: NSFont.systemFont(ofSize: 13, weight: .medium)
            )
            contentHeight = min(max(textHeight + 66, 112), 220)
        case .result:
            contentHeight = 164
        }

        return NSSize(width: width, height: contentHeight)
    }

    private func popoverWidth(for presentation: AppModel.StatusPresentation) -> CGFloat {
        let expression: String
        let result: String
        let errorMessage: String

        switch presentation.content {
        case let .result(resolvedExpression, value):
            expression = resolvedExpression
            result = value
            errorMessage = ""
        case let .error(message):
            expression = ""
            result = ""
            errorMessage = message
        case .loading, .empty:
            expression = ""
            result = ""
            errorMessage = ""
        }

        let expressionWidth = width(of: expression, font: .monospacedSystemFont(ofSize: 14, weight: .medium))
        let resultWidth = width(of: result, font: .systemFont(ofSize: 38, weight: .bold))
        let errorWidth = width(of: errorMessage, font: .systemFont(ofSize: 13, weight: .medium))
        let contentWidth = max(expressionWidth, resultWidth, errorWidth)

        return min(max(contentWidth + 34, 220), 360)
    }

    private func width(of text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func measuredHeight(of text: String, width: CGFloat, font: NSFont) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }

        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )

        return ceil(rect.height)
    }
}
