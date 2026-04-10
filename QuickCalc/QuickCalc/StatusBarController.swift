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
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        configureStatusItem()
        configurePopover()
        bindModel()
    }

    func showPopover() {
        guard let button = statusItem.button else { return }

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
        popover.contentSize = popoverSize(expression: "", result: "", errorMessage: nil, isProcessing: false)
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView(model: model) { [weak self] in
                self?.popover.performClose(nil)
            }
        )
    }

    private func bindModel() {
        model.$menuBarTitle
            .combineLatest(model.$lastExpression, model.$lastResult, model.$errorMessage)
            .combineLatest(model.$isProcessing)
            .sink { [weak self] combinedValues, isProcessing in
                let (title, expression, result, errorMessage) = combinedValues
                self?.updateButton(title: title, expression: expression, result: result, errorMessage: errorMessage, isProcessing: isProcessing)
                self?.popover.contentSize = self?.popoverSize(
                    expression: expression,
                    result: result,
                    errorMessage: errorMessage,
                    isProcessing: isProcessing
                ) ?? NSSize(width: 240, height: 120)
            }
            .store(in: &cancellables)
    }

    private func updateButton(
        title: String,
        expression: String,
        result: String,
        errorMessage: String?,
        isProcessing: Bool
    ) {
        guard let button = statusItem.button else { return }

        button.title = title.isEmpty ? "" : " \(title)"
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading

        if isProcessing {
            button.image = NSImage(systemSymbolName: "hourglass.circle", accessibilityDescription: "QuickCalc processing")
            button.toolTip = "Processing"
            return
        }

        if let errorMessage {
            button.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "QuickCalc error")
            button.toolTip = errorMessage
            return
        }

        button.image = NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: "QuickCalc")
        button.toolTip = result.isEmpty ? "QuickCalc" : "\(expression) = \(result)"
    }

    private func popoverSize(
        expression: String,
        result: String,
        errorMessage: String?,
        isProcessing: Bool
    ) -> NSSize {
        let width = popoverWidth(expression: expression, result: result, errorMessage: errorMessage)

        let contentHeight: CGFloat
        if isProcessing || (result.isEmpty && errorMessage == nil) {
            contentHeight = 78
        } else if let errorMessage {
            let textHeight = measuredHeight(
                of: errorMessage,
                width: width - 32,
                font: NSFont.systemFont(ofSize: 13, weight: .medium)
            )
            contentHeight = min(max(textHeight + 66, 112), 220)
        } else {
            contentHeight = 164
        }

        return NSSize(width: width, height: contentHeight)
    }

    private func popoverWidth(expression: String, result: String, errorMessage: String?) -> CGFloat {
        let expressionWidth = width(of: expression, font: .monospacedSystemFont(ofSize: 14, weight: .medium))
        let resultWidth = width(of: result, font: .systemFont(ofSize: 38, weight: .bold))
        let errorWidth = width(of: errorMessage ?? "", font: .systemFont(ofSize: 13, weight: .medium))
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
