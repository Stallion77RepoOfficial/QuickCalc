//
//  StatusPopoverView.swift
//  QuickCalc
//
//  Created by Codex on 7.04.2026.
//

import SwiftUI

struct StatusPopoverView: View {
    let presentation: AppModel.StatusPresentation
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content

            HStack {
                Spacer()

                Button("Close", action: onClose)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.content {
        case .loading:
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 8)
        case let .error(errorMessage):
            Text(errorMessage)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case let .result(expression, value):
            VStack(alignment: .leading, spacing: 8) {
                if !expression.isEmpty {
                    Text(expression)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Text(value)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.1, green: 0.35, blue: 0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
            }
        case .empty:
            EmptyView()
        }
    }
}
