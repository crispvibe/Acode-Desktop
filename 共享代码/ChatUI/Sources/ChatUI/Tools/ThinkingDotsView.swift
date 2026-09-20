import SwiftUI

public struct ThinkingDotsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    public init() {}

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(ChatTheme.muted.opacity(0.72))
                    .frame(width: 7, height: 7)
                    .scaleEffect(reduceMotion ? 1 : (isAnimating ? 1.0 : 0.72))
                    .opacity(reduceMotion ? 0.72 : (isAnimating ? 0.92 : 0.42))
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.62)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.18),
                        value: isAnimating
                    )
            }
        }
        .frame(width: 38, height: 12)
        .accessibilityLabel("正在思考")
        .onAppear {
            guard !reduceMotion else { return }
            isAnimating = true
        }
    }
}

public struct ThinkingIndicatorRow: View {
    public init() {}

    public var body: some View {
        HStack(alignment: .bottom, spacing: 9) {
            ThinkingDotsView()
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(ChatTheme.systemBubbleFill)
                        .shadow(color: .black.opacity(0.055), radius: 14, x: 0, y: 8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(ChatTheme.toolStroke, lineWidth: 1)
                )
            Spacer(minLength: 42)
        }
    }
}
