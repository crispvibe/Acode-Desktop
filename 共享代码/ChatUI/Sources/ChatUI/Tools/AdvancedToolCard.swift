import ChatCore
import Foundation
import SwiftUI

private func compactPath(_ path: String) -> String {
    let components = path.split(separator: "/").map(String.init)
    guard components.count > 3 else { return path }
    return components.suffix(3).joined(separator: "/")
}

private func preview(_ value: String, limit: Int) -> String {
    let compact = value
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard compact.count > limit else { return compact }
    return String(compact.prefix(limit - 1)) + "…"
}

public struct AdvancedToolCard: View {
    public let message: ChatMessage
    public var onPermissionDecision: ((String, ChatUIPermissionDecision) -> Void)?
    public var onInteractiveSubmit: ((ChatInteractiveResponse) -> Void)?

    public init(
        message: ChatMessage,
        onPermissionDecision: ((String, ChatUIPermissionDecision) -> Void)? = nil,
        onInteractiveSubmit: ((ChatInteractiveResponse) -> Void)? = nil
    ) {
        self.message = message
        self.onPermissionDecision = onPermissionDecision
        self.onInteractiveSubmit = onInteractiveSubmit
    }

    public var body: some View {
        if message.kind == .permissionRequest, let onPermissionDecision {
            PermissionRequestCard(message: message, onDecision: onPermissionDecision)
        } else if message.kind == .interactiveRequest, let onInteractiveSubmit {
            InteractiveRequestCard(message: message, onSubmit: onInteractiveSubmit)
        } else if let payload = message.agentToolPayload {
            AgentToolCard(payload: payload)
        } else if let payload = message.todoToolPayload {
            TodoToolCard(payload: payload)
        } else if let payload = message.fileChangeToolPayload {
            FileChangeCompactToolRow(payload: payload)
        } else if let payload = message.readToolPayload {
            ReadToolCard(payload: payload)
        } else if let payload = message.searchToolPayload {
            SearchToolCard(payload: payload)
        } else if let payload = message.terminalToolPayload {
            TerminalToolCard(payload: payload)
        } else {
            GenericToolCallRow(message: message)
        }
    }
}

private struct ReadToolCard: View {
    let payload: ReadToolPayload

    var body: some View {
        SharedGlassCard(cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 0) {
                toolHeader(systemImage: "doc.text.magnifyingglass", title: payload.displayPath, trailing: "\(payload.lines.count) lines")
                Divider().opacity(0.16)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(payload.lines.prefix(80).enumerated()), id: \.offset) { index, line in
                        codeLine(number: payload.startLine + index, text: line)
                    }
                    if payload.lines.count > 80 {
                        Text("… 还有 \(payload.lines.count - 80) 行")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(ChatTheme.muted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                }
                .background(Color.black.opacity(0.035))
            }
        }
    }

    private func codeLine(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("\(number)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(ChatTheme.muted.opacity(0.65))
                .frame(width: 38, alignment: .trailing)
                .padding(.trailing, 8)
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ChatTheme.ink.opacity(0.84))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 10)
        .padding(.vertical, 2)
    }
}

private struct SearchToolCard: View {
    let payload: SearchToolPayload

    var body: some View {
        SharedGlassCard(cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 0) {
                toolHeader(systemImage: payload.mode == .glob ? "folder" : "magnifyingglass", title: payload.title, trailing: payload.countText)
                Divider().opacity(0.16)
                LazyVStack(alignment: .leading, spacing: 0) {
                    if payload.rows.isEmpty {
                        Text(payload.mode == .glob ? "无匹配文件" : "无匹配结果")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ChatTheme.muted)
                            .padding(12)
                    } else {
                        ForEach(Array(payload.rows.prefix(80).enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: payload.mode == .glob ? "doc" : "text.magnifyingglass")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(ChatTheme.muted.opacity(0.72))
                                    .frame(width: 14, height: 14)
                                Text(row)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(ChatTheme.ink.opacity(0.82))
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                        }
                    }
                }
                .background(Color.black.opacity(0.03))
            }
        }
    }
}

private struct TerminalToolCard: View {
    let payload: TerminalToolPayload

    var body: some View {
        SharedGlassCard(cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 0) {
                toolHeader(systemImage: "terminal", title: payload.commandTitle, trailing: payload.exitText)
                Divider().opacity(0.16)
                if payload.output.isEmpty {
                    Text("命令已执行")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ChatTheme.muted)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(payload.output)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(ChatTheme.ink.opacity(0.86))
                            .padding(12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.045))
                }
            }
        }
    }
}

private struct AgentToolCard: View {
    let payload: AgentToolPayload

    var body: some View {
        SharedGlassCard(cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.gearshape")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ChatTheme.muted)
                    Text(payload.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ChatTheme.ink.opacity(0.88))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let kind = payload.kind {
                        Text(kind)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ChatTheme.muted)
                    }
                }
                if let prompt = payload.prompt {
                    Text(prompt)
                        .font(.system(size: 12))
                        .lineSpacing(3)
                        .foregroundStyle(ChatTheme.ink.opacity(0.78))
                        .lineLimit(6)
                }
            }
            .padding(14)
        }
    }
}

private func toolHeader(systemImage: String, title: String, trailing: String?) -> some View {
    HStack(spacing: 8) {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ChatTheme.muted)
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ChatTheme.ink.opacity(0.86))
            .lineLimit(1)
            .truncationMode(.middle)
        Spacer(minLength: 8)
        if let trailing {
            Text(trailing)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(ChatTheme.muted)
                .lineLimit(1)
        }
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .background(Color.white.opacity(0.42))
}

private struct SharedGlassCard<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.58), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 22, x: 0, y: 14)
    }
}

private struct FileChangeCompactToolRow: View {
    let payload: FileChangeToolPayload

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(ChatTheme.muted.opacity(0.5))
                .frame(width: 8)

            Image(systemName: payload.systemImage)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(ChatTheme.muted.opacity(0.7))
                .frame(width: 12, height: 12)

            Text(payload.displayPath)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(ChatTheme.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(payload.compactStatusText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(ChatTheme.muted.opacity(0.72))
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FileChangeLineView: View {
    let line: FileChangePreviewLine
    let number: Int

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("\(number)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(ChatTheme.muted.opacity(0.7))
                .frame(width: 28, alignment: .trailing)
                .padding(.trailing, 6)

            Text(line.marker)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(line.tint)
                .frame(width: 14, alignment: .center)

            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 11, weight: line.isChange ? .medium : .regular, design: .monospaced))
                .foregroundStyle(line.textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.background)
    }
}

private struct FileChangeToolPayload {
    let toolName: String
    let path: String?
    let lines: [FileChangePreviewLine]

    var displayPath: String {
        guard let path, !path.isEmpty else { return "文件已更新" }
        return path
    }

    var systemImage: String {
        switch toolName {
        case "write": "square.and.pencil"
        case "multiedit", "multi_edit": "text.badge.checkmark"
        default: "pencil.line"
        }
    }

    var statusText: String {
        toolName == "write" ? "写入" : "已更新"
    }

    var compactStatusText: String {
        statusText
    }

    var addedCount: Int { lines.filter { $0.marker == "+" }.count }
    var removedCount: Int { lines.filter { $0.marker == "-" }.count }
}

private struct FileChangePreviewLine {
    let marker: String
    let text: String

    var isChange: Bool { marker == "+" || marker == "-" }

    var tint: Color {
        if marker == "+" { return Color(red: 0.13, green: 0.55, blue: 0.30) }
        if marker == "-" { return Color(red: 0.78, green: 0.20, blue: 0.20) }
        return ChatTheme.muted
    }

    var textColor: Color {
        if marker == "+" { return Color(red: 0.07, green: 0.36, blue: 0.18) }
        if marker == "-" { return Color(red: 0.55, green: 0.10, blue: 0.10) }
        return ChatTheme.ink.opacity(0.78)
    }

    var background: Color {
        if marker == "+" { return Color(red: 0.83, green: 0.97, blue: 0.86) }
        if marker == "-" { return Color(red: 0.99, green: 0.86, blue: 0.86) }
        return Color.black.opacity(0.02)
    }
}

private struct TodoToolCard: View {
    let payload: TodoToolPayload

    var body: some View {
        SharedGlassCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ChatTheme.muted)
                        .frame(width: 20, height: 20)
                    Text("任务列表")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ChatTheme.ink)
                    Spacer(minLength: 8)
                    if let countsText = payload.countsText {
                        Text(countsText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ChatTheme.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                }

                LazyVStack(alignment: .leading, spacing: 0) {
                    if payload.rows.isEmpty {
                        Text("暂无任务")
                            .font(.system(size: 13))
                            .foregroundStyle(ChatTheme.muted)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(Array(payload.rows.prefix(40).enumerated()), id: \.element.id) { index, row in
                            TodoToolRow(row: row)
                            if index < min(payload.rows.count, 40) - 1 {
                                Divider()
                                    .opacity(0.18)
                                    .padding(.leading, 30)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

private struct TodoToolRow: View {
    let row: TodoToolItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(row.tint)
                .frame(width: 20, height: 20)

            Text(row.content)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ChatTheme.ink.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Text(row.statusTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ChatTheme.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.045), in: Capsule())
        }
        .padding(.vertical, 8)
    }
}

private struct TodoToolPayload {
    let rows: [TodoToolItem]

    var countsText: String? {
        guard !rows.isEmpty else { return nil }
        let inProgress = rows.filter { $0.normalizedStatus == "in_progress" || $0.normalizedStatus == "in progress" }.count
        let completed = rows.filter { $0.normalizedStatus == "completed" }.count
        let added = max(rows.count - inProgress - completed, 0)
        return "新增 \(added) · 进行中 \(inProgress) · 已完成 \(completed)"
    }
}

private struct TodoToolItem: Identifiable {
    let id = UUID()
    let content: String
    let status: String

    var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var statusTitle: String {
        switch normalizedStatus {
        case "completed": "已完成"
        case "in_progress", "in progress": "进行中"
        case "pending": "新增"
        default: normalizedStatus.isEmpty ? "新增" : status
        }
    }

    var symbolName: String {
        switch normalizedStatus {
        case "completed": "checkmark.circle.fill"
        case "in_progress", "in progress": "circle.lefthalf.filled"
        default: "circle"
        }
    }

    var tint: Color {
        switch normalizedStatus {
        case "completed": Color.green
        case "in_progress", "in progress": Color.orange
        default: Color.gray.opacity(0.65)
        }
    }
}

private struct ReadToolPayload {
    let path: String?
    let startLine: Int
    let lines: [String]

    var displayPath: String {
        guard let path, !path.isEmpty else { return "文件预览" }
        return compactPath(path)
    }
}

private struct SearchToolPayload {
    enum Mode {
        case grep
        case glob
    }

    let mode: Mode
    let title: String
    let rows: [String]

    var countText: String {
        mode == .glob ? "\(rows.count) files" : "\(rows.count) matches"
    }
}

private struct TerminalToolPayload {
    let command: String?
    let output: String
    let exitCode: String?

    var commandTitle: String {
        guard let command, !command.isEmpty else { return "Terminal" }
        return "$ \(preview(command, limit: 88))"
    }

    var exitText: String? {
        guard let exitCode, !exitCode.isEmpty else { return nil }
        return "exit \(exitCode)"
    }
}

private struct AgentToolPayload {
    let title: String
    let kind: String?
    let prompt: String?
}

private extension ChatMessage {
    var readToolPayload: ReadToolPayload? {
        guard toolName == "read" else { return nil }
        let path = firstToolStringValue(keys: ["file_path", "filePath", "path", "target_file", "targetFile"], in: text) ?? firstPath(in: text)
        let startLine = firstToolStringValue(keys: ["start_line", "startLine", "line", "offset"], in: text)
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
        let content = firstToolStringValue(keys: ["content", "text", "output", "result"], in: text) ?? (ToolJSONSummary.looksLikeJSON(in: text) ? "" : text)
        let lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard !lines.isEmpty || path != nil else { return nil }
        return ReadToolPayload(path: path, startLine: max(startLine, 1), lines: lines.isEmpty ? [""] : lines)
    }

    var searchToolPayload: SearchToolPayload? {
        let name = toolName
        guard name == "grep" || name == "glob" else { return nil }
        let pattern = firstToolStringValue(keys: ["pattern", "query", "regex", "glob"], in: text)
        let rows = searchRows(from: text)
        let title = pattern.map { "pattern: \(preview($0, limit: 72))" } ?? (name == "glob" ? "文件列表" : "匹配结果")
        return SearchToolPayload(mode: name == "glob" ? .glob : .grep, title: title, rows: rows)
    }

    var terminalToolPayload: TerminalToolPayload? {
        let name = toolName
        guard name == "bash" || kind == .command || kind == .commandOutput else { return nil }
        let command = firstToolStringValue(keys: ["command", "cmd", "shell_command", "shellCommand"], in: text)
        let output = cleanedTerminalOutput(firstToolStringValue(keys: ["stdout", "stderr", "output", "result", "error"], in: text))
            ?? (kind == .commandOutput ? text : "")
        let exitCode = firstToolStringValue(keys: ["exit_code", "exitCode", "code", "status_code", "statusCode"], in: text)
        return TerminalToolPayload(command: command, output: output, exitCode: exitCode)
    }

    var agentToolPayload: AgentToolPayload? {
        guard toolName == "agent" || "\(title) \(subtitle)".lowercased().contains("agent") else { return nil }
        let agentKind = firstToolStringValue(keys: ["subagent_type", "subagentType", "agentType", "agent_type"], in: text)
        let description = firstToolStringValue(keys: ["description", "summary", "title"], in: text)
        let prompt = firstToolStringValue(keys: ["prompt", "instruction", "instructions"], in: text).map { preview($0, limit: 420) }
        return AgentToolPayload(title: description ?? "Agent task", kind: agentKind, prompt: prompt)
    }

    var fileChangeToolPayload: FileChangeToolPayload? {
        guard isFileChangeToolMessage else { return nil }
        let object = firstJSONObject(in: text)
        let toolName = normalizedToolName
        let path = object.flatMap(Self.filePath(in:)) ?? firstPath(in: text)
        let lines = Self.fileChangeLines(toolName: toolName, object: object, text: text)
        guard !lines.isEmpty || path != nil else { return nil }
        return FileChangeToolPayload(
            toolName: toolName,
            path: path,
            lines: lines.isEmpty ? [FileChangePreviewLine(marker: " ", text: "已完成文件修改")] : lines
        )
    }

    var isFileChangeToolMessage: Bool {
        if kind == .diff { return true }
        return ["edit", "write", "multiedit", "multi_edit"].contains(normalizedToolName)
    }

    var normalizedToolName: String {
        toolName
    }

    var toolName: String {
        let header = "\(title) \(subtitle)".lowercased()
        let compactHeader = header
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        if compactHeader.contains("multiedit") { return "multiedit" }
        if compactHeader.contains("todowrite") { return "todowrite" }
        if compactHeader.contains("read") { return "read" }
        if compactHeader.contains("grep") { return "grep" }
        if compactHeader.contains("glob") { return "glob" }
        if compactHeader.contains("bash") { return "bash" }
        if compactHeader.contains("agent") { return "agent" }
        if compactHeader.contains("write") { return "write" }
        if compactHeader.contains("edit") { return "edit" }
        if kind == .diff { return "diff" }
        if kind == .command || kind == .commandOutput { return "bash" }
        return ""
    }

    var todoToolPayload: TodoToolPayload? {
        guard isTodoWriteToolMessage else { return nil }
        return TodoToolPayload(rows: Self.todoTaskRows(from: text))
    }

    var isTodoWriteToolMessage: Bool {
        let header = "\(title) \(subtitle)".lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        if header.contains("todowrite") { return true }
        return text.lowercased().contains("\"todos\"")
    }

    private static func fileChangeLines(toolName: String, object: Any?, text: String) -> [FileChangePreviewLine] {
        if let object {
            let generated = generatedChangeLines(toolName: toolName, object: object)
            if !generated.isEmpty { return generated }
        }

        let rawLines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.hasPrefix("diff --git") && !$0.hasPrefix("+++") && !$0.hasPrefix("---") && !$0.hasPrefix("@@") }
        let diffLines = rawLines.compactMap(diffPreviewLine(from:))
        if diffLines.contains(where: { $0.marker == "+" || $0.marker == "-" }) { return diffLines }
        return []
    }

    private static func diffPreviewLine(from line: String) -> FileChangePreviewLine? {
        if line.hasPrefix("+") {
            return FileChangePreviewLine(marker: "+", text: String(line.dropFirst()))
        }
        if line.hasPrefix("-") {
            return FileChangePreviewLine(marker: "-", text: String(line.dropFirst()))
        }
        let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return FileChangePreviewLine(marker: " ", text: text)
    }

    private static func generatedChangeLines(toolName: String, object: Any) -> [FileChangePreviewLine] {
        if let dictionary = object as? [String: Any] {
            if let edits = caseInsensitiveValue("edits", in: dictionary) as? [Any] {
                let rows = edits.flatMap { generatedChangeLines(toolName: "edit", object: $0) }
                if !rows.isEmpty { return rows }
            }

            var rows: [FileChangePreviewLine] = []
            if let oldString = stringValue(for: ["old_string", "oldString", "old", "before"], in: dictionary) {
                rows += previewLines(from: oldString, marker: "-")
            }
            if let newString = stringValue(for: ["new_string", "newString", "replacement", "after"], in: dictionary) {
                rows += previewLines(from: newString, marker: "+")
            }
            if rows.isEmpty, toolName == "write", let content = stringValue(for: ["content", "text"], in: dictionary) {
                rows += previewLines(from: content, marker: "+")
            }
            if !rows.isEmpty { return rows }

            for key in nestedKeys {
                guard let value = caseInsensitiveValue(key, in: dictionary) else { continue }
                let nestedRows = generatedChangeLines(toolName: toolName, object: value)
                if !nestedRows.isEmpty { return nestedRows }
            }
        }

        if let array = object as? [Any] {
            return array.flatMap { generatedChangeLines(toolName: toolName, object: $0) }
        }

        if let string = object as? String,
           let nested = jsonObject(from: string) {
            return generatedChangeLines(toolName: toolName, object: nested)
        }

        return []
    }

    private static func previewLines(from value: String, marker: String) -> [FileChangePreviewLine] {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(20)
            .map { FileChangePreviewLine(marker: marker, text: String($0)) }
    }

    private func firstJSONObject(in text: String) -> Any? {
        if let object = Self.jsonObject(from: text) { return object }
        for fragment in Self.jsonFragments(in: text) {
            if let object = Self.jsonObject(from: fragment) { return object }
        }
        return nil
    }

    private func firstToolStringValue(keys: [String], in text: String) -> String? {
        guard let object = firstJSONObject(in: text) else { return nil }
        return Self.firstStringValue(keys: keys, in: object)
    }

    private static func firstStringValue(keys: [String], in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in keys {
                if let value = caseInsensitiveValue(key, in: dictionary) {
                    if let string = value as? String {
                        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return trimmed }
                    }
                    if let number = value as? NSNumber { return number.stringValue }
                }
            }
            for key in nestedKeys {
                guard let value = caseInsensitiveValue(key, in: dictionary), let nested = firstStringValue(keys: keys, in: value) else { continue }
                return nested
            }
            for value in dictionary.values {
                if let nested = firstStringValue(keys: keys, in: value) { return nested }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let nested = firstStringValue(keys: keys, in: value) { return nested }
            }
        }
        if let string = object as? String,
           let nested = jsonObject(from: string) {
            return firstStringValue(keys: keys, in: nested)
        }
        return nil
    }

    private static func filePath(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            if let path = stringValue(for: ["file_path", "filePath", "path", "target_file", "targetFile"], in: dictionary) {
                return path
            }
            for key in nestedKeys {
                guard let value = caseInsensitiveValue(key, in: dictionary), let path = filePath(in: value) else { continue }
                return path
            }
            for value in dictionary.values {
                if let path = filePath(in: value) { return path }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let path = filePath(in: value) { return path }
            }
        }
        if let string = object as? String,
           let nested = jsonObject(from: string) {
            return filePath(in: nested)
        }
        return nil
    }

    private func firstPath(in value: String) -> String? {
        let pattern = #"(?<!\w)(?:/[^\s`\"'<>|]+|[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        for match in regex.matches(in: value, range: range) {
            guard let matchRange = Range(match.range, in: value) else { continue }
            let path = String(value[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)。），"))
            if path.contains(".") { return path }
        }
        return nil
    }

    private func searchRows(from value: String) -> [String] {
        if let object = firstJSONObject(in: value) {
            let rows = Self.stringRows(in: object)
            if !rows.isEmpty { return rows }
        }
        let rows = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("{") && !$0.hasSuffix("}") }
        if rows.isEmpty, ToolJSONSummary.looksLikeJSON(in: value) { return [] }
        return rows
    }

    private static func stringRows(in object: Any) -> [String] {
        if let dictionary = object as? [String: Any] {
            for key in ["matches", "files", "results", "output", "result"] {
                guard let value = caseInsensitiveValue(key, in: dictionary) else { continue }
                let rows = stringRows(in: value)
                if !rows.isEmpty { return rows }
            }
            for value in dictionary.values {
                let rows = stringRows(in: value)
                if !rows.isEmpty { return rows }
            }
        }
        if let array = object as? [Any] {
            return array.flatMap { stringRows(in: $0) }
        }
        if let string = object as? String {
            if let nested = jsonObject(from: string) {
                let rows = stringRows(in: nested)
                if !rows.isEmpty { return rows }
            }
            return string
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if let number = object as? NSNumber {
            return [number.stringValue]
        }
        return []
    }

    private func cleanedTerminalOutput(_ value: String?) -> String? {
        guard let value else { return nil }
        let lines = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") }
        let output = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    static func todoTaskRows(from text: String) -> [TodoToolItem] {
        if let object = jsonObject(from: text) {
            let rows = todoTaskRows(in: object)
            if !rows.isEmpty { return rows }
        }
        for fragment in jsonFragments(in: text) {
            guard let object = jsonObject(from: fragment) else { continue }
            let rows = todoTaskRows(in: object)
            if !rows.isEmpty { return rows }
        }
        return todoContentRows(fromPlainText: text)
    }

    private static func todoTaskRows(in object: Any) -> [TodoToolItem] {
        if let dictionary = object as? [String: Any] {
            if let todos = caseInsensitiveValue("todos", in: dictionary) as? [Any] {
                let rows = todos.compactMap(todoTaskRow(from:))
                if !rows.isEmpty { return rows }
            }
            for key in nestedKeys {
                guard let value = caseInsensitiveValue(key, in: dictionary) else { continue }
                let rows = todoTaskRows(in: value)
                if !rows.isEmpty { return rows }
            }
            for value in dictionary.values {
                let rows = todoTaskRows(in: value)
                if !rows.isEmpty { return rows }
            }
        }
        if let array = object as? [Any] {
            let rows = array.compactMap(todoTaskRow(from:))
            if !rows.isEmpty { return rows }
            for value in array {
                let rows = todoTaskRows(in: value)
                if !rows.isEmpty { return rows }
            }
        }
        if let string = object as? String,
           let nested = jsonObject(from: string) {
            return todoTaskRows(in: nested)
        }
        return []
    }

    private static func todoTaskRow(from object: Any) -> TodoToolItem? {
        guard let dictionary = object as? [String: Any],
              let content = stringValue(for: ["content", "title", "task", "demand"], in: dictionary) else { return nil }
        let status = stringValue(for: ["status"], in: dictionary) ?? ""
        return TodoToolItem(content: content, status: status)
    }

    private static func jsonFragments(in value: String) -> [String] {
        var fragments: [String] = []
        var startIndex: String.Index?
        var stack: [Character] = []
        var isInsideString = false
        var isEscaped = false
        var index = value.startIndex

        while index < value.endIndex {
            let character = value[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "{" || character == "[" {
                if stack.isEmpty { startIndex = index }
                stack.append(character)
            } else if character == "}" || character == "]" {
                if let last = stack.last, (last == "{" && character == "}" || last == "[" && character == "]") {
                    stack.removeLast()
                    if stack.isEmpty, let fragmentStartIndex = startIndex {
                        fragments.append(String(value[fragmentStartIndex...index]))
                        startIndex = nil
                    }
                } else {
                    stack.removeAll()
                    startIndex = nil
                }
            }
            index = value.index(after: index)
        }

        return fragments
    }

    private static func todoContentRows(fromPlainText value: String) -> [TodoToolItem] {
        guard let regex = try? NSRegularExpression(pattern: #""content"\s*:\s*"((?:\\.|[^"\\])*)""#) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let contentRange = Range(match.range(at: 1), in: value) else { return nil }
            let content = unescapedJSONString(String(value[contentRange])).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? nil : TodoToolItem(content: content, status: "")
        }
    }

    private static func unescapedJSONString(_ value: String) -> String {
        guard let data = "\"\(value)\"".data(using: .utf8),
              let string = try? JSONSerialization.jsonObject(with: data) as? String else { return value }
        return string
    }


    private static func stringValue(for keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            guard let value = caseInsensitiveValue(key, in: dictionary) else { continue }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let number = value as? NSNumber { return number.stringValue }
        }
        return nil
    }

    private static func caseInsensitiveValue(_ key: String, in dictionary: [String: Any]) -> Any? {
        dictionary.first { $0.key.lowercased() == key.lowercased() }?.value
    }

    private static func jsonObject(from text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static var nestedKeys: [String] {
        ["input", "args", "arguments", "params", "data", "message", "content"]
    }
}
