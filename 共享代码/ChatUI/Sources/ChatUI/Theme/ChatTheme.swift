import SwiftUI

public enum ChatTheme {
    public static let ink = Color.primary
    public static let muted = Color.secondary
    public static let userBubbleFill = Color.black
    public static let userBubbleText = Color.white
    public static let assistantText = Color.primary.opacity(0.92)
    public static let systemBubbleFill = Color.primary.opacity(0.055)
    public static let errorBubbleFill = Color.red.opacity(0.075)
    public static let errorText = Color.red
    public static let toolSurface = Color.primary.opacity(0.055)
    public static let toolStroke = Color.primary.opacity(0.08)
    public static let codeSurface = Color.primary.opacity(0.055)
    public static let chipTint = Color.blue
}

public struct ChatPressButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(chatPressAnimation(duration: 0.16), value: configuration.isPressed)
    }

    private func chatPressAnimation(duration: TimeInterval) -> Animation {
        if #available(iOS 17.0, macOS 14.0, *) {
            return .smooth(duration: duration)
        }
        return .easeInOut(duration: duration)
    }
}

public extension ButtonStyle where Self == ChatPressButtonStyle {
    static var chatPress: ChatPressButtonStyle { ChatPressButtonStyle() }
}
