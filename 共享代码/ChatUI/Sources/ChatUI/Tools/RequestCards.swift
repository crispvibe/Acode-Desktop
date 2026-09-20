import ChatCore
import SwiftUI

public enum ChatUIPermissionDecision {
    case deny
    case allow
    case allowForSession
}

public struct PermissionRequestCard: View {
    public let message: ChatMessage
    public var onDecision: (String, ChatUIPermissionDecision) -> Void

    public init(message: ChatMessage, onDecision: @escaping (String, ChatUIPermissionDecision) -> Void) {
        self.message = message
        self.onDecision = onDecision
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ChatTheme.muted)
                    .frame(width: 14)
                Text(message.title.isEmpty ? "需要权限" : message.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ChatTheme.muted)
                Spacer(minLength: 0)
            }

            Text(message.text)
                .font(.system(size: 11))
                .foregroundStyle(ChatTheme.muted)

            if message.status == "waiting", let requestID = message.requestID {
                HStack(spacing: 8) {
                    permissionButton("拒绝") {
                        onDecision(requestID, .deny)
                    }

                    permissionButton("允许") {
                        onDecision(requestID, .allow)
                    }

                    permissionButton("本会话允许") {
                        onDecision(requestID, .allowForSession)
                    }
                }
            }
        }
        .padding(10)
        .background(ChatTheme.toolSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ChatTheme.toolStroke, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ChatTheme.ink.opacity(0.82))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(ChatTheme.systemBubbleFill)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ChatTheme.toolStroke, lineWidth: 1))
    }
}

public struct InteractiveRequestCard: View {
    public let message: ChatMessage
    public var onSubmit: (ChatInteractiveResponse) -> Void
    @State private var selectedOptionIDs: Set<String> = []
    @State private var customText = ""

    private var request: ChatInteractiveRequest? { message.interactiveRequest }
    private var isWaiting: Bool { request?.status == .waiting || message.status == ChatInteractiveStatus.waiting.rawValue }

    public init(message: ChatMessage, onSubmit: @escaping (ChatInteractiveResponse) -> Void) {
        self.message = message
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ChatTheme.muted)
                    .frame(width: 14, height: 14)
                Text(nonEmpty(request?.title) ?? nonEmpty(message.title) ?? "需要选择")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ChatTheme.ink.opacity(0.78))
                Spacer(minLength: 0)
                Text(isWaiting ? "等待选择" : "已记录")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ChatTheme.muted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(ChatTheme.toolSurface)
                    .clipShape(Capsule())
            }

            Text(nonEmpty(request?.prompt) ?? message.text)
                .font(.system(size: 11))
                .foregroundStyle(ChatTheme.muted)
                .lineSpacing(2)

            if let request, isWaiting {
                controls(for: request)
            } else {
                Text("已提交选择")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ChatTheme.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(ChatTheme.toolSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .padding(10)
        .background(ChatTheme.toolSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ChatTheme.toolStroke, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func controls(for request: ChatInteractiveRequest) -> some View {
        switch request.mode {
        case .singleChoice:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(request.options) { option in
                    Button {
                        submit(request: request, selectedIDs: [option.id], customText: nil)
                    } label: {
                        optionRow(option, selected: false, multiple: false)
                    }
                    .buttonStyle(.chatPress)
                }
            }
        case .multipleChoice:
            multipleChoiceControls(request)
        case .text:
            textInput(request)
        }

        if request.allowCustomInput && request.mode == .singleChoice {
            textInput(request)
        }
    }

    private func multipleChoiceControls(_ request: ChatInteractiveRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(selectedOptionIDs.isEmpty ? "尚未选择" : "已选 \(selectedOptionIDs.count) 项")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selectedOptionIDs.isEmpty ? ChatTheme.muted : ChatTheme.ink.opacity(0.78))
                Spacer(minLength: 0)
                if !selectedOptionIDs.isEmpty {
                    Button("清空") { selectedOptionIDs.removeAll() }
                        .buttonStyle(.chatPress)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ChatTheme.muted)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(request.options) { option in
                    let isSelected = selectedOptionIDs.contains(option.id)
                    Button {
                        toggleSelection(option.id)
                    } label: {
                        optionRow(option, selected: isSelected, multiple: true)
                    }
                    .buttonStyle(.chatPress)
                }
            }

            HStack(spacing: 8) {
                submitButton(disabled: selectedOptionIDs.isEmpty) {
                    submit(request: request, selectedIDs: selectedIDs(in: request), customText: nil)
                }
                if selectedOptionIDs.isEmpty {
                    Text("至少选择一项后提交。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(ChatTheme.muted)
                }
            }

            if request.allowCustomInput {
                textInput(request, selectedIDs: selectedIDs(in: request))
            }
        }
    }

    private func optionRow(_ option: ChatInteractiveOption, selected: Bool, multiple: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: selected ? (multiple ? "checkmark.square.fill" : "largecircle.fill.circle") : (multiple ? "square" : "circle"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? ChatTheme.ink.opacity(0.72) : ChatTheme.muted.opacity(0.5))
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .foregroundStyle(ChatTheme.ink.opacity(selected ? 0.9 : 0.86))
                if !option.detail.isEmpty {
                    Text(option.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(ChatTheme.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(selected ? ChatTheme.systemBubbleFill : ChatTheme.toolSurface)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? ChatTheme.toolStroke : ChatTheme.toolStroke.opacity(0.9), lineWidth: 1)
        )
    }

    private func textInput(_ request: ChatInteractiveRequest, selectedIDs: [String] = []) -> some View {
        HStack(spacing: 6) {
            TextField(request.placeholder.isEmpty ? "输入自定义回复" : request.placeholder, text: $customText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(ChatTheme.systemBubbleFill)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ChatTheme.toolStroke, lineWidth: 1))
            submitButton(selectedIDs.isEmpty ? "提交自定义" : "提交选择和补充", disabled: customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                submit(request: request, selectedIDs: selectedIDs, customText: customText)
            }
        }
    }

    private func submitButton(_ title: String = "提交选择", disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(disabled ? ChatTheme.muted.opacity(0.45) : ChatTheme.ink.opacity(0.82))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(disabled ? ChatTheme.toolSurface.opacity(0.55) : ChatTheme.systemBubbleFill)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ChatTheme.toolStroke, lineWidth: 1))
            .disabled(disabled)
    }

    private func toggleSelection(_ optionID: String) {
        if selectedOptionIDs.contains(optionID) {
            selectedOptionIDs.remove(optionID)
        } else {
            selectedOptionIDs.insert(optionID)
        }
    }

    private func selectedIDs(in request: ChatInteractiveRequest) -> [String] {
        request.options.map(\.id).filter { selectedOptionIDs.contains($0) }
    }

    private func submit(request: ChatInteractiveRequest, selectedIDs: [String], customText: String?) {
        let trimmed = customText?.trimmingCharacters(in: .whitespacesAndNewlines)
        onSubmit(ChatInteractiveResponse(
            requestID: request.id,
            selectedOptionIDs: selectedIDs,
            customText: trimmed?.isEmpty == true ? nil : trimmed
        ))
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
