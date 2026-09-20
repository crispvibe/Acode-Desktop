import SwiftUI
import UIKit

/// 局域网 6 位码配对弹层（§4.2 POST /pair）：展示目标主机名 + 数字输入框。
/// 提交由父视图走 `DeviceConnectViewModel.pair`，成功后父视图负责 dismiss。
struct PairCodeSheet: View {
    let pending: DeviceConnectViewModel.PendingPairing
    let isWorking: Bool
    let errorMessage: String?
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                WhiteGlassBackground()
                    .ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.key("输入配对码"))
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(Color.codevokeInk)
                            Text(L10n.format("在 %@ 的电脑端设置页查看 6 位数字配对码。", pending.displayName))
                                .font(.system(size: 14))
                                .foregroundStyle(Color.codevokeMuted)
                        }

                        SettingsSectionCard {
                            VStack(alignment: .leading, spacing: 14) {
                                SettingsCardTitle("配对码", subtitle: "5 分钟内有效，一次有效")
                                TextField(L10n.string("6 位数字"), text: $code)
                                    .keyboardType(.numberPad)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                                    .multilineTextAlignment(.center)
                                    .padding(11)
                                    .codevokeGlass(cornerRadius: 16)
                                    .background(.white.opacity(0.56), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.codevokeGlassStroke, lineWidth: 1))
                                    .focused($codeFieldFocused)
                                    .codevokeOnChange(of: code) { _, newValue in
                                        let digits = newValue.filter(\.isNumber)
                                        if digits != newValue || digits.count > 6 {
                                            code = String(digits.prefix(6))
                                        }
                                    }
                                Button {
                                    onSubmit(code)
                                } label: {
                                    Text(L10n.key(isWorking ? "连接中…" : "配对并连接"))
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 13)
                                        .background(Color.black, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                }
                                .buttonStyle(.codevokePress)
                                .disabled(isWorking || code.count != 6)
                                if let errorMessage, !errorMessage.isEmpty {
                                    Text(errorMessage)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.red.opacity(0.85))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(16)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 22)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .codevokeTopBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.codevokeInk)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.codevokePress)
                    .accessibilityLabel(L10n.string("取消"))
                }
            }
        }
        .codevokePresentationCornerRadius(28)
        .onAppear { codeFieldFocused = true }
    }
}

/// 手动粘贴连接串弹层（§4.4：`acode://pair?d=<base64url(JSON)>`）。
/// 无摄像头/远程协助场景的配对载体。
struct ConnectionStringSheet: View {
    let isWorking: Bool
    let errorMessage: String?
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var connectionString = ""

    var body: some View {
        NavigationStack {
            ZStack {
                WhiteGlassBackground()
                    .ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.key("输入连接串"))
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(Color.codevokeInk)
                            Text(L10n.key("粘贴电脑端设置页复制的 acode:// 连接串，无需同一局域网。"))
                                .font(.system(size: 14))
                                .foregroundStyle(Color.codevokeMuted)
                        }

                        SettingsSectionCard {
                            VStack(alignment: .leading, spacing: 14) {
                                SettingsCardTitle("连接串", subtitle: "acode://pair?d= 开头")
                                TextField(L10n.string("acode://pair?d=…"), text: $connectionString, axis: .vertical)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.system(size: 13, design: .monospaced))
                                    .lineLimit(3...6)
                                    .padding(11)
                                    .codevokeGlass(cornerRadius: 16)
                                    .background(.white.opacity(0.56), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.codevokeGlassStroke, lineWidth: 1))
                                HStack(spacing: 10) {
                                    Button(L10n.string("粘贴剪贴板")) {
                                        if let text = UIPasteboard.general.string {
                                            connectionString = text
                                        }
                                    }
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.codevokeInk)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(.white.opacity(0.72), in: Capsule())
                                    .overlay(Capsule().stroke(Color.black.opacity(0.06), lineWidth: 1))
                                    .buttonStyle(.codevokePress)
                                    Spacer(minLength: 0)
                                }
                                Button {
                                    onSubmit(connectionString)
                                } label: {
                                    Text(L10n.key(isWorking ? "连接中…" : "配对并连接"))
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 13)
                                        .background(Color.black, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                }
                                .buttonStyle(.codevokePress)
                                .disabled(isWorking || connectionString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                if let errorMessage, !errorMessage.isEmpty {
                                    Text(errorMessage)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.red.opacity(0.85))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(16)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 22)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .codevokeTopBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.codevokeInk)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.codevokePress)
                    .accessibilityLabel(L10n.string("取消"))
                }
            }
        }
        .codevokePresentationCornerRadius(28)
    }
}
