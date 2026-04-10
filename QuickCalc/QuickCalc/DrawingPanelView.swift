//
//  DrawingPanelView.swift
//  QuickCalc
//
//  Created by Codex on 7.04.2026.
//

import SwiftUI

struct DrawingPanelView: View {
    @ObservedObject var canvasController: CanvasController

    let onIdle: ([Stroke], CGSize) -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.06)
                .ignoresSafeArea()

            TrackpadCanvasView(controller: canvasController, onIdle: onIdle)
                .ignoresSafeArea()

            Button("Close", action: onClose)
                .buttonStyle(.borderedProminent)
                .tint(Color.white.opacity(0.16))
                .padding(.top, 26)
                .padding(.trailing, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
