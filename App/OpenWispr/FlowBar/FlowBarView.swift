import OpenWisprCore
import SwiftUI

struct FlowBarView: View {
    private static let barCount = 13

    let model: AppModel
    let hover: FlowBarHover
    @State private var levels = [Float](repeating: 0, count: barCount)
    @Namespace private var glass

    private var state: FlowBarState { model.dictation.flowBarState }

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if let tooltip {
                Text(tooltip)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            GlassEffectContainer(spacing: 10) {
                pill
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { hover.pillFrame = $0 }
            }
        }
        .padding(.bottom, 8)
        .frame(width: FlowBarPanel.size.width, height: FlowBarPanel.size.height)
        .overlay(alignment: .topLeading) {
            if model.isUITesting { AppliedColorScheme(id: "flow-bar-color-scheme").font(.caption2) }
        }
        .animation(.spring(duration: 0.3), value: state)
        .animation(.spring(duration: 0.25), value: hover.isHovered)
        .task(id: isListening) {
            levels = Array(repeating: 0, count: Self.barCount)
            guard isListening else { return }
            while !Task.isCancelled {
                levels = Array(levels.dropFirst()) + [model.level()]
                try? await Task.sleep(for: .milliseconds(45))
            }
        }
    }

    private var isListening: Bool {
        switch state {
        case .initializing, .listening: true
        case .hidden, .resting, .processing, .notice: false
        }
    }

    private var tooltip: String? {
        if let progress = model.models.progress { return progress.label }
        if case .resting = state, hover.isHovered {
            return "Click or hold \(Key.comboLabel(model.store.settings.shortcuts.ptt)) to start dictating"
        }
        return nil
    }

    @ViewBuilder
    private var pill: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .resting:
            Button {
                model.dictation.start(.handsFree)
            } label: {
                Group {
                    if hover.isHovered {
                        Bars(levels: Array(repeating: 0, count: Self.barCount), idle: true)
                            .padding(.horizontal, 14)
                    } else {
                        Capsule().fill(.secondary.opacity(0.5)).frame(width: 28, height: 4)
                    }
                }
                .frame(height: hover.isHovered ? 30 : 10)
                .padding(.horizontal, hover.isHovered ? 6 : 8)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .glassEffectID("pill", in: glass)
            .accessibilityIdentifier("flow-bar-start")
            .accessibilityLabel("Start hands-free dictation")
        case let .initializing(mode), let .listening(mode):
            HStack(spacing: 8) {
                if mode == .handsFree {
                    Button { model.dictation.cancel() } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("cancel", in: glass)
                    .help("Cancel (Esc)")
                    .accessibilityIdentifier("flow-bar-cancel")
                }
                Bars(levels: levels, idle: { if case .initializing = state { true } else { false } }())
                    .frame(height: 22)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("pill", in: glass)
                    .accessibilityIdentifier("flow-bar-listening")
                if mode == .handsFree {
                    Button { model.dictation.stop() } label: {
                        RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 9, height: 9).frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.red).interactive(), in: .circle)
                    .glassEffectID("stop", in: glass)
                    .help("Finish")
                    .accessibilityIdentifier("flow-bar-stop")
                }
            }
        case .processing:
            ProcessingDots()
                .frame(width: 60, height: 22)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
                .glassEffectID("pill", in: glass)
                .accessibilityIdentifier("flow-bar-processing")
        case let .notice(message, tone):
            Text(message)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(maxWidth: 340)
                .glassEffect(tone == .error ? .regular.tint(.red.opacity(0.35)) : .regular, in: .capsule)
                .glassEffectID("pill", in: glass)
                .accessibilityIdentifier("flow-bar-notice")
        }
    }
}

private struct Bars: View {
    let levels: [Float]
    let idle: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.primary.opacity(idle ? 0.35 : 0.9))
                    .frame(width: 3, height: max(3, CGFloat(levels[index]) * 22))
            }
        }
        .animation(.linear(duration: 0.045), value: levels)
    }
}

private struct ProcessingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(.primary)
                        .frame(width: 6, height: 6)
                        .opacity(0.35 + 0.65 * max(0, sin(time * 5 - Double(index) * 0.8)))
                }
            }
        }
    }
}
