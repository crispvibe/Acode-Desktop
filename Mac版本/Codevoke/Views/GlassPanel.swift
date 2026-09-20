import AppKit
import SwiftUI

enum AppTheme {
    static let windowTint = adaptiveColor(light: .white.withAlphaComponent(0.46), dark: .black.withAlphaComponent(0.38))
    static let editorSurface = adaptiveColor(light: .white.withAlphaComponent(0.84), dark: NSColor(calibratedWhite: 0.09, alpha: 0.92))
    static let settingsGlassSurface = adaptiveColor(light: .white.withAlphaComponent(0.76), dark: NSColor(calibratedWhite: 0.10, alpha: 0.72))
    static let relayActiveGlassSurface = adaptiveColor(light: .white.withAlphaComponent(0.72), dark: .white.withAlphaComponent(0.08))
    static let panelSurface = adaptiveColor(light: .white.withAlphaComponent(0.26), dark: .black.withAlphaComponent(0.20))
    static let controlSurface = adaptiveColor(light: .white.withAlphaComponent(0.40), dark: .white.withAlphaComponent(0.08))
    static let selectedSurface = adaptiveColor(light: NSColor.controlAccentColor.withAlphaComponent(0.10), dark: NSColor.controlAccentColor.withAlphaComponent(0.20))
    static let sidebarSelectedSurface = adaptiveColor(light: NSColor.controlAccentColor.withAlphaComponent(0.18), dark: NSColor.controlAccentColor.withAlphaComponent(0.28))
    static let pageBackground = Color(nsColor: .windowBackgroundColor)
    static let cardSurface = adaptiveColor(light: .white, dark: NSColor(calibratedWhite: 0.14, alpha: 1))
    static let secondaryCardSurface = adaptiveColor(light: NSColor(calibratedWhite: 0.98, alpha: 1), dark: NSColor(calibratedWhite: 0.18, alpha: 1))
    static let inputSurface = adaptiveColor(light: .white, dark: NSColor(calibratedWhite: 0.11, alpha: 1))
    static let buttonSurface = adaptiveColor(light: .white, dark: NSColor(calibratedWhite: 0.18, alpha: 1))
    static let buttonPressedSurface = adaptiveColor(light: NSColor.black.withAlphaComponent(0.035), dark: NSColor.white.withAlphaComponent(0.12))
    static let editorBackground = Color(nsColor: editorBackgroundColor)
    static let editorStatusBackground = adaptiveColor(light: .white, dark: NSColor(calibratedWhite: 0.11, alpha: 1))
    static let editorGutterBackground = adaptiveColor(light: .white, dark: NSColor(calibratedWhite: 0.10, alpha: 1))
    static let editorSelection = Color(nsColor: editorSelectionColor)
    static let chatSurfaceTint = adaptiveColor(light: .white.withAlphaComponent(0.74), dark: .black.withAlphaComponent(0.18))
    static let composerSurfaceTint = adaptiveColor(light: .white.withAlphaComponent(0.88), dark: .white.withAlphaComponent(0.08))
    static let toolSurface = adaptiveColor(light: .white, dark: NSColor(calibratedWhite: 0.15, alpha: 1))
    static let toolMutedSurface = adaptiveColor(light: NSColor.black.withAlphaComponent(0.025), dark: NSColor.white.withAlphaComponent(0.06))
    static let codePreviewHeaderSurface = adaptiveColor(light: .white.withAlphaComponent(0.86), dark: .white.withAlphaComponent(0.06))
    static let codePreviewSurface = adaptiveColor(light: .white.withAlphaComponent(0.92), dark: NSColor(calibratedWhite: 0.12, alpha: 1))
    static let fileTreeName = Color.primary
    static let fileTreeModifiedName = adaptiveColor(light: NSColor(calibratedRed: 0.12, green: 0.42, blue: 0.78, alpha: 1), dark: NSColor(calibratedRed: 0.40, green: 0.68, blue: 1.00, alpha: 1))
    static let fileTreeHoverSurface = adaptiveColor(light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.08))
    static let hairline = Color(nsColor: hairlineColor)
    static let weakHairline = Color(nsColor: weakHairlineColor)
    static let resizeHandle = adaptiveColor(light: NSColor.black.withAlphaComponent(0.07), dark: NSColor.white.withAlphaComponent(0.12))
    static let resizeHandleActive = adaptiveColor(light: NSColor.black.withAlphaComponent(0.18), dark: NSColor.white.withAlphaComponent(0.24))
    static let softShadow = adaptiveColor(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.black.withAlphaComponent(0.30))

    static let editorBackgroundColor = adaptiveNSColor(light: .white, dark: NSColor(calibratedWhite: 0.08, alpha: 1))
    static let editorGutterBackgroundColor = adaptiveNSColor(light: .white, dark: NSColor(calibratedWhite: 0.10, alpha: 1))
    static let editorTextColor = adaptiveNSColor(light: NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.20, alpha: 1), dark: NSColor(calibratedRed: 0.86, green: 0.88, blue: 0.91, alpha: 1))
    static let editorSecondaryTextColor = adaptiveNSColor(light: NSColor(calibratedRed: 0.52, green: 0.57, blue: 0.66, alpha: 0.82), dark: NSColor(calibratedRed: 0.55, green: 0.60, blue: 0.68, alpha: 1))
    static let editorSelectionColor = adaptiveNSColor(light: NSColor(calibratedRed: 0.74, green: 0.84, blue: 1.00, alpha: 0.55), dark: NSColor(calibratedRed: 0.18, green: 0.38, blue: 0.72, alpha: 0.70))
    static let hairlineColor = adaptiveNSColor(light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.white.withAlphaComponent(0.12))
    static let weakHairlineColor = adaptiveNSColor(light: NSColor.black.withAlphaComponent(0.035), dark: NSColor.white.withAlphaComponent(0.08))

    static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: adaptiveNSColor(light: light, dark: dark))
    }

    static func adaptiveNSColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

struct GlassPanel<Content: View>: View {
    var material: NSVisualEffectView.Material = .sidebar
    var radius: CGFloat = 20
    var surfaceOpacity: Double = 0.62
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background {
                ZStack {
                    VisualEffectView(material: material, blendingMode: .withinWindow)
                        .opacity(surfaceOpacity)
                    AppTheme.panelSurface
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(AppTheme.weakHairline, lineWidth: 1)
            )
            .shadow(color: AppTheme.softShadow, radius: 18, y: 8)
    }
}

enum ResizeHandleAxis {
    case horizontal
    case vertical

    var cursor: NSCursor {
        switch self {
        case .horizontal: .resizeLeftRight
        case .vertical: .resizeUpDown
        }
    }

    func coordinate(in event: NSEvent) -> CGFloat {
        switch self {
        case .horizontal: event.locationInWindow.x
        case .vertical: event.locationInWindow.y
        }
    }
}

struct ResizeHandleInputView: NSViewRepresentable {
    var axis: ResizeHandleAxis = .horizontal
    var onHover: (Bool) -> Void
    var onDragBegan: () -> Void
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: (CGFloat) -> Void

    func makeNSView(context: Context) -> ResizeHandleInputNSView {
        let view = ResizeHandleInputNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: ResizeHandleInputNSView, context: Context) {
        nsView.axis = axis
        nsView.onHover = onHover
        nsView.onDragBegan = onDragBegan
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

final class ResizeHandleInputNSView: NSView {
    var axis: ResizeHandleAxis = .horizontal
    var onHover: (Bool) -> Void = { _ in }
    var onDragBegan: () -> Void = {}
    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: (CGFloat) -> Void = { _ in }
    private var dragStartPosition: CGFloat?

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis.cursor)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover(false)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartPosition = axis.coordinate(in: event)
        onDragBegan()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartPosition else { return }
        onDragChanged(axis.coordinate(in: event) - dragStartPosition)
    }

    override func mouseUp(with event: NSEvent) {
        let translation = dragStartPosition.map { axis.coordinate(in: event) - $0 } ?? 0
        dragStartPosition = nil
        onDragEnded(translation)
    }
}

struct PrimaryGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(configuration.isPressed ? AppTheme.buttonPressedSurface : AppTheme.controlSurface)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(AppTheme.hairline, lineWidth: 1)
            )
    }
}

struct CircularIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var background: Color = .clear
    var border: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .background(configuration.isPressed ? background.opacity(0.72) : background)
            .clipShape(Circle())
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .overlay {
                if let border {
                    Circle().stroke(border, lineWidth: 1)
                }
            }
    }
}

struct MiniIconButtonStyle: ButtonStyle {
    var width: CGFloat = 24
    var height: CGFloat = 24
    var cornerRadius: CGFloat = 8
    var background: Color = .clear

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: width, height: height)
            .background(configuration.isPressed ? background.opacity(0.72) : background)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
