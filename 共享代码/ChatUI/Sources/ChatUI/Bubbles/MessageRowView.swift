import ChatCore
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public struct MessageRowView: View {
    public let message: ChatMessage
    public var streamingText: String?
    public var onCopy: ((String) -> Void)?
    public var onOpenFile: ((ChatFileReference) -> Void)?
    public var onEditUserMessage: ((ChatMessage) -> Void)?
    public var advancedToolCard: ((ChatMessage) -> AnyView)?
    private let displayText: String
    private let shouldHideRow: Bool
    private let isUser: Bool
    private let isError: Bool
    private let isSystem: Bool

    public init(
        message: ChatMessage,
        streamingText: String? = nil,
        onCopy: ((String) -> Void)? = nil,
        onOpenFile: ((ChatFileReference) -> Void)? = nil,
        onEditUserMessage: ((ChatMessage) -> Void)? = nil,
        advancedToolCard: ((ChatMessage) -> AnyView)? = nil
    ) {
        self.message = message
        self.streamingText = streamingText
        self.onCopy = onCopy
        self.onOpenFile = onOpenFile
        self.onEditUserMessage = onEditUserMessage
        self.advancedToolCard = advancedToolCard
        let resolvedText = streamingText ?? message.text
        self.displayText = resolvedText
        self.shouldHideRow = ChatMessageFilter.shouldHideMessage(
            kind: message.kind,
            title: message.title,
            subtitle: message.subtitle,
            text: resolvedText
        )
        self.isUser = message.kind == .user
        self.isError = message.kind == .error
        self.isSystem = message.kind == .system
    }

    public var body: some View {
        if shouldHide {
            EmptyView()
        } else if message.kind == .reasoning {
            reasoningRow
        } else if message.kind.isOperationalOutput {
            operationalRow
        } else if message.kind == .user {
            userRow
        } else {
            conversationRow
        }
    }

    private var shouldHide: Bool { shouldHideRow }

    private var userRow: some View {
        VStack(alignment: .trailing, spacing: 0) {
            conversationRow
                .contextMenu { copyAndEditMenu }
            userActionBar
        }
    }

    @ViewBuilder
    private var copyAndEditMenu: some View {
        Button {
            copyMessageText()
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        if message.kind == .user {
            Button {
                onEditUserMessage?(message)
            } label: {
                Label("编辑", systemImage: "square.and.pencil")
            }
        }
    }

    private var userActionBar: some View {
        HStack(spacing: 4) {
            Button {
                copyMessageText()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ChatTheme.muted)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.chatPress)

            Button {
                onEditUserMessage?(message)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ChatTheme.muted)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.chatPress)
        }
        .padding(.trailing, 2)
    }

    private var conversationRow: some View {
        HStack(alignment: .bottom, spacing: 9) {
            if isUser { Spacer(minLength: 42) }
            bubble
            if !isUser { Spacer(minLength: isSystem ? 0 : 42) }
        }
        .contextMenu { copyAndEditMenu }
    }

    @ViewBuilder
    private var bubble: some View {
        if isAssistant {
            AssistantOutputText(text: displayText, onOpenFile: onOpenFile)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(displayText.isEmpty ? " " : displayText)
                    .font(.system(size: isSystem ? 13 : 15))
                    .lineSpacing(4)
                    .foregroundStyle(isUser ? ChatTheme.userBubbleText : foregroundColor)
                if !message.attachments.isEmpty {
                    MessageAttachmentStripView(attachments: message.attachments, onOpenFile: onOpenFile)
                }
            }
            .padding(.horizontal, isSystem ? 13 : 15)
            .padding(.vertical, isSystem ? 10 : 12)
            .frame(maxWidth: isSystem ? .infinity : nil, alignment: .leading)
            .background(backgroundShape)
            .overlay(borderShape)
        }
    }

    private var reasoningRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ChatTheme.muted)
                .frame(width: 16, height: 16)
            Text(displayText.isEmpty ? " " : displayText)
                .font(.system(size: 12))
                .lineSpacing(3)
                .foregroundStyle(ChatTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var operationalRow: some View {
        if let advancedToolCard {
            advancedToolCard(message)
        } else {
            AdvancedToolCard(message: message)
        }
    }

    private var isAssistant: Bool { !isUser && !isError && !isSystem }

    private var foregroundColor: Color {
        if isError { return ChatTheme.errorText }
        return ChatTheme.ink
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: isSystem ? 18 : 20, style: .continuous)
            .fill(backgroundColor)
            .shadow(color: .black.opacity(isUser ? 0.10 : 0.055), radius: 14, x: 0, y: 8)
    }

    private var borderShape: some View {
        RoundedRectangle(cornerRadius: isSystem ? 18 : 20, style: .continuous)
            .stroke(isUser ? .clear : ChatTheme.toolStroke, lineWidth: 1)
    }

    private var backgroundColor: Color {
        if isUser { return ChatTheme.userBubbleFill }
        if isError { return ChatTheme.errorBubbleFill }
        if isSystem { return ChatTheme.systemBubbleFill }
        return ChatTheme.systemBubbleFill
    }

    private func copyMessageText() {
        let text = displayText
        if let onCopy {
            onCopy(text)
        } else {
            copyToClipboard(text)
        }
    }
}

private struct MessageAttachmentStripView: View {
    let attachments: [ChatMessageAttachment]
    let onOpenFile: ((ChatFileReference) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    MessageAttachmentTileView(attachment: attachment, onOpenFile: onOpenFile)
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxWidth: 260, alignment: .leading)
    }
}

private struct MessageAttachmentTileView: View {
    let attachment: ChatMessageAttachment
    let onOpenFile: ((ChatFileReference) -> Void)?

    var body: some View {
        Button {
            onOpenFile?(ChatFileReference(path: attachment.path))
        } label: {
            ZStack(alignment: .topTrailing) {
                preview
                    .frame(width: 56, height: 56)
                    .background(ChatTheme.systemBubbleFill)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(ChatTheme.toolStroke, lineWidth: 1)
                    )
                Image(systemName: attachment.kind == .image ? "photo" : "doc")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(ChatTheme.muted.opacity(0.85))
                    .padding(4)
            }
        }
        .buttonStyle(.chatPress)
        .disabled(onOpenFile == nil)
    }

    @ViewBuilder
    private var preview: some View {
        if attachment.kind == .image, let image = previewImage {
            image
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipped()
        } else {
            VStack(spacing: 4) {
                Image(systemName: attachment.kind == .image ? "photo" : "doc")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ChatTheme.muted)
                Text(attachment.filename)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(ChatTheme.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                    .frame(width: 46)
            }
            .frame(width: 56, height: 56)
        }
    }

    private var previewImage: Image? {
        guard let data = attachment.thumbnailData else { return nil }
#if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
#else
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
#endif
    }
}

extension MessageRowView: Equatable {
    public static func == (lhs: MessageRowView, rhs: MessageRowView) -> Bool {
        lhs.message == rhs.message && lhs.streamingText == rhs.streamingText
    }
}
