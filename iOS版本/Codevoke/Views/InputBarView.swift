import SwiftUI
import UIKit

struct InputBarView: View {
    private static let minInputHeight: CGFloat = 52
    private static let maxInputHeight: CGFloat = 150
    private static let inputFontSize: CGFloat = 15
    private static let inputVerticalInset: CGFloat = 22

    @Binding var text: String
    @Binding var isFocused: Bool
    @State private var inputHeight: CGFloat = minInputHeight
    @State private var isAttachmentMenuPresented = false
    let isSending: Bool
    let isEnabled: Bool
    let attachments: [RemoteUploadedAttachment]
    let isUploadingAttachment: Bool
    let takePhoto: () -> Void
    let selectImage: () -> Void
    let selectFile: () -> Void
    let removeAttachment: (RemoteUploadedAttachment) -> Void
    let previewAttachment: (RemoteUploadedAttachment) -> Void
    let send: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            attachmentButton
            inputField
            sendButton
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottomLeading) {
            if isAttachmentMenuPresented {
                attachmentMenu
                    .offset(x: 0, y: -58)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .zIndex(20)
            }
        }
        .animation(.codevokeSmooth(duration: 0.18), value: isAttachmentMenuPresented)
        .codevokeOnChange(of: isEnabled) { _, enabled in
            if !enabled {
                isAttachmentMenuPresented = false
            }
        }
    }

    private var attachmentStrip: some View {
        AttachmentStripView(
            attachments: attachments,
            isUploadingAttachment: isUploadingAttachment,
            removeAttachment: removeAttachment,
            previewAttachment: previewAttachment
        )
    }
}

struct AttachmentStripView: View {
    let attachments: [RemoteUploadedAttachment]
    let isUploadingAttachment: Bool
    let removeAttachment: (RemoteUploadedAttachment) -> Void
    let previewAttachment: (RemoteUploadedAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    attachmentTile(attachment)
                }
                if isUploadingAttachment {
                    VStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(L10n.key("上传中"))
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color.codevokeMuted)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.36), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.52), lineWidth: 1)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 56)
    }

    private func attachmentTile(_ attachment: RemoteUploadedAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = attachment.previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: attachment.fileIconName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.codevokeInk.opacity(0.72))
                        Text(attachment.filename)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color.codevokeInk.opacity(0.78))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .truncationMode(.middle)
                            .frame(width: 42)
                    }
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.34), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.55), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.055), radius: 10, x: 0, y: 5)
            .onTapGesture {
                previewAttachment(attachment)
            }

            Button {
                removeAttachment(attachment)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.codevokeInk.opacity(0.72), Color.white.opacity(0.86))
            }
            .buttonStyle(.codevokePress)
            .offset(x: 5, y: -5)
        }
        .frame(width: 58, height: 58)
    }
}

private extension InputBarView {

    private var attachmentButton: some View {
        Button {
            guard isEnabled, !isUploadingAttachment else { return }
            isAttachmentMenuPresented.toggle()
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.codevokeMuted)
                .frame(width: 52, height: 52)
                .codevokeGlass(cornerRadius: 26)
                .overlay(
                    Circle().stroke(.white.opacity(0.72), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(.codevokePress)
        .disabled(!isEnabled || isUploadingAttachment)
        .fixedSize()
    }

    private var attachmentMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            attachmentMenuButton(title: "拍照", systemImage: "camera", action: takePhoto)
            attachmentMenuButton(title: "选择图片", systemImage: "photo", action: selectImage)
            attachmentMenuButton(title: "选择文件", systemImage: "doc", action: selectFile)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.codevokeGlassStroke, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 22, x: 0, y: 12)
    }

    private func attachmentMenuButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            isAttachmentMenuPresented = false
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.codevokeInk)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.76), in: Circle())
                Text(L10n.key(title))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.codevokeInk)
                Spacer(minLength: 0)
            }
            .frame(width: 132)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.codevokePress)
    }

    private var inputField: some View {
        SelectableMessageInputView(
            text: $text,
            isFocused: $isFocused,
            height: $inputHeight,
            placeholder: L10n.string(isEnabled ? "输入消息…" : "先连接远程设备并选择项目"),
            isEnabled: isEnabled,
            minHeight: Self.minInputHeight,
            maxHeight: Self.maxInputHeight,
            fontSize: Self.inputFontSize,
            verticalInset: Self.inputVerticalInset,
            canSubmit: { currentText in canSend(text: currentText) },
            send: send
        )
        .frame(height: inputHeight)
        .padding(.horizontal, 14)
        .padding(.vertical, 0)
        .frame(minWidth: 0, maxWidth: .infinity)
        .layoutPriority(2)
        .codevokeGlass(cornerRadius: 26)
        .overlay(
            Capsule().stroke(.white.opacity(0.72), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 10)
        .clipShape(Capsule())
    }

    private var sendButton: some View {
        Button {
            if shouldShowStopButton {
                stop()
            } else {
                send()
            }
        } label: {
            Image(systemName: shouldShowStopButton ? "stop.fill" : "arrow.up")
                .font(.system(size: shouldShowStopButton ? 16 : 18, weight: .semibold))
                .foregroundStyle(shouldShowStopButton ? .white : (canSend ? Color.codevokeInk : Color.codevokeMuted))
                .frame(width: 52, height: 52)
                .background(
                    Group {
                        if shouldShowStopButton {
                            Circle().fill(Color.codevokeInk)
                        } else {
                            Color.clear.codevokeGlass(cornerRadius: 26)
                        }
                    }
                )
                .overlay(
                    Circle().stroke(.white.opacity(shouldShowStopButton ? 0.0 : 0.72), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(.codevokePress)
        .disabled(!isSending && !canSend)
        .fixedSize()
    }

    private var shouldShowStopButton: Bool {
        isSending
    }

    private var canSend: Bool {
        canSend(text: text)
    }

    private func canSend(text: String) -> Bool {
        isEnabled && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }
}

private struct SelectableMessageInputView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var height: CGFloat
    let placeholder: String
    let isEnabled: Bool
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let fontSize: CGFloat
    let verticalInset: CGFloat
    let canSubmit: (String) -> Bool
    let send: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = UIColor(Color.codevokeInk)
        textView.tintColor = .black
        textView.isScrollEnabled = false
        textView.showsHorizontalScrollIndicator = false
        textView.alwaysBounceVertical = false
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 10, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.heightTracksTextView = false
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.returnKeyType = .send
        textView.autocorrectionType = .default
        textView.smartDashesType = .default
        textView.smartQuotesType = .default
        textView.textDragInteraction?.isEnabled = true
        textView.adjustsFontForContentSizeCategory = false
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.updateActions(canSubmit: canSubmit, send: send)
        if textView.text != text {
            textView.text = text
        }
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.textColor = UIColor(Color.codevokeInk)
        textView.font = .systemFont(ofSize: fontSize)
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.heightTracksTextView = false
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.textContainer.maximumNumberOfLines = 0
        textView.showsHorizontalScrollIndicator = false
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.returnKeyType = .send
        textView.backgroundColor = .clear
        updatePlaceholder(in: textView)
        recalculateHeight(for: textView)
        updateFocus(in: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: $isFocused,
            height: $height,
            minHeight: minHeight,
            maxHeight: maxHeight,
            fontSize: fontSize,
            verticalInset: verticalInset,
            canSubmit: canSubmit,
            send: send
        )
    }

    private func recalculateHeight(for textView: UITextView) {
        DispatchQueue.main.async {
            textView.layoutIfNeeded()
            let measuredHeight = textView.sizeThatFits(CGSize(width: max(1, textView.bounds.width), height: .greatestFiniteMagnitude)).height
            let clampedHeight = min(max(ceil(measuredHeight), minHeight), maxHeight)
            textView.isScrollEnabled = measuredHeight > maxHeight
            if abs(height - clampedHeight) > 0.5 {
                height = clampedHeight
            }
        }
    }

    private func updatePlaceholder(in textView: UITextView) {
        let label = placeholderLabel(in: textView)
        label.text = placeholder
        label.isHidden = !text.isEmpty
    }

    private func placeholderLabel(in textView: UITextView) -> UILabel {
        if let label = textView.viewWithTag(3917) as? UILabel {
            return label
        }
        let label = UILabel()
        label.tag = 3917
        label.font = .systemFont(ofSize: fontSize)
        label.textColor = UIColor(Color.codevokeMuted).withAlphaComponent(0.48)
        label.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
            label.topAnchor.constraint(equalTo: textView.topAnchor, constant: 12)
        ])
        return label
    }

    private func updateFocus(in textView: UITextView) {
        DispatchQueue.main.async {
            if isFocused, isEnabled, !textView.isFirstResponder {
                textView.becomeFirstResponder()
            } else if (!isFocused || !isEnabled), textView.isFirstResponder {
                textView.resignFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        @Binding private var isFocused: Bool
        @Binding private var height: CGFloat
        private let minHeight: CGFloat
        private let maxHeight: CGFloat
        private let fontSize: CGFloat
        private let verticalInset: CGFloat
        private var canSubmit: (String) -> Bool
        private var send: () -> Void

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            height: Binding<CGFloat>,
            minHeight: CGFloat,
            maxHeight: CGFloat,
            fontSize: CGFloat,
            verticalInset: CGFloat,
            canSubmit: @escaping (String) -> Bool,
            send: @escaping () -> Void
        ) {
            _text = text
            _isFocused = isFocused
            _height = height
            self.minHeight = minHeight
            self.maxHeight = maxHeight
            self.fontSize = fontSize
            self.verticalInset = verticalInset
            self.canSubmit = canSubmit
            self.send = send
        }

        func updateActions(canSubmit: @escaping (String) -> Bool, send: @escaping () -> Void) {
            self.canSubmit = canSubmit
            self.send = send
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
            (textView.viewWithTag(3917) as? UILabel)?.isHidden = !textView.text.isEmpty
            recalculateHeight(for: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !isFocused {
                isFocused = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if isFocused {
                isFocused = false
            }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            if replacement.isReturnKeySubmission {
                guard textView.markedTextRange == nil else { return true }
                text = textView.text
                guard canSubmit(textView.text) else { return false }
                send()
                return false
            }
            return true
        }

        private func recalculateHeight(for textView: UITextView) {
            textView.layoutIfNeeded()
            let measuredHeight = textView.sizeThatFits(CGSize(width: max(1, textView.bounds.width), height: .greatestFiniteMagnitude)).height
            let clampedHeight = min(max(ceil(measuredHeight), minHeight), maxHeight)
            textView.isScrollEnabled = measuredHeight > maxHeight
            if abs(height - clampedHeight) > 0.5 {
                height = clampedHeight
            }
        }
    }

    private static func measuredHeight(for text: String, width: CGFloat, fontSize: CGFloat, verticalInset: CGFloat) -> CGFloat {
        let lineHeight = UIFont.systemFont(ofSize: fontSize).lineHeight
        let effectiveWidth = max(1, width)
        guard !text.isEmpty else {
            return ceil(lineHeight + verticalInset)
        }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        let boundingRect = (text as NSString).boundingRect(
            with: CGSize(width: effectiveWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize),
                .paragraphStyle: paragraphStyle
            ],
            context: nil
        )
        return ceil(max(lineHeight, boundingRect.height) + verticalInset)
    }
}

private extension String {
    var isReturnKeySubmission: Bool {
        !isEmpty && rangeOfCharacter(from: .newlines) != nil && trimmingCharacters(in: .newlines).isEmpty
    }
}

extension RemoteUploadedAttachment {
    var previewImage: UIImage? {
        guard let previewData else { return nil }
        return UIImage(data: previewData)
    }

    var fileIconName: String {
        switch filename.fileExtensionLowercased {
        case "pdf": "doc.richtext"
        case "zip", "rar", "7z", "gz", "tar": "archivebox"
        case "mp4", "mov", "m4v", "avi": "play.rectangle"
        case "mp3", "wav", "m4a", "aac": "waveform"
        case "txt", "md", "json", "csv", "log", "xml": "doc.text"
        default: "doc"
        }
    }
}

private extension String {
    var fileExtensionLowercased: String {
        (self as NSString).pathExtension.lowercased()
    }
}
