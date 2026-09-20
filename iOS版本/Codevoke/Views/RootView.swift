import SwiftUI
import UIKit

struct RootView: View {
    @StateObject private var viewModel: ChatViewModel
    @State private var sidebarDragOffset: CGFloat = 0

    init(initialConfig: RemoteChatConfig? = nil) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(initialConfig: initialConfig))
    }

    private let sidebarLeadingPadding: CGFloat = 10
    private let edgeSwipeWidth: CGFloat = 32
    private let sidebarCloseIntentMinimum: CGFloat = 24
    private let sidebarCloseIntentRatio: CGFloat = 1.35

    var body: some View {
        GeometryReader { geometry in
            let resolvedSidebarWidth = sidebarWidth(for: geometry.size.width)
            let hiddenOffset = hiddenSidebarOffset(for: resolvedSidebarWidth)
            ZStack(alignment: .leading) {
                WhiteGlassBackground()
                    .ignoresSafeArea()

                ChatView(viewModel: viewModel)

                edgeSwipeHotZone(height: geometry.size.height, hiddenOffset: hiddenOffset)

                if viewModel.isSidebarVisible {
                    Color.black.opacity(0.24)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            closeSidebar()
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in }
                                .onEnded { _ in }
                        )
                        .transition(.opacity)
                        .zIndex(2)
                }

                SidebarView(
                    state: viewModel.sidebarState,
                    startNewChat: {
                        viewModel.startNewChat()
                    },
                    refresh: {
                        Task { await viewModel.refresh() }
                    },
                    selectProject: { project in
                        Task { await viewModel.selectProject(project) }
                    },
                    selectModel: { model in
                        viewModel.selectModel(model)
                    },
                    selectSession: { session in
                        Task { await viewModel.selectSession(session) }
                    },
                    openParentDirectory: {
                        Task { await viewModel.openParentDirectory() }
                    },
                    openFileEntry: { entry in
                        Task { await viewModel.openFileEntry(entry) }
                    },
                    copyFilePath: { entry in
                        copyAbsolutePath(entry)
                    }
                )
                    .equatable()
                    .frame(width: resolvedSidebarWidth)
                    .padding(.leading, sidebarLeadingPadding)
                    .offset(x: sidebarOffset(hiddenOffset: hiddenOffset))
                    .shadow(color: .black.opacity(viewModel.isSidebarVisible ? 0.18 : 0), radius: 24, x: 6, y: 0)
                    .simultaneousGesture(sidebarDragGesture)
                    .zIndex(3)

                if viewModel.isSettingsPresented {
                    SettingsView(
                        chatViewModel: viewModel,
                        close: {
                            viewModel.isSettingsPresented = false
                        }
                    )
                    .transition(.move(edge: .trailing))
                    .zIndex(10)
                }
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: viewModel.isSidebarVisible)
        .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.86), value: sidebarDragOffset)
        .task {
            await viewModel.refresh()
        }
    }

    private func sidebarWidth(for availableWidth: CGFloat) -> CGFloat {
        min(max(availableWidth * 0.70, 272), 312)
    }

    private func hiddenSidebarOffset(for width: CGFloat) -> CGFloat {
        -(width + sidebarLeadingPadding + 24)
    }

    private func sidebarOffset(hiddenOffset: CGFloat) -> CGFloat {
        if viewModel.isSidebarVisible {
            return min(0, sidebarDragOffset)
        }
        return hiddenOffset + max(0, sidebarDragOffset)
    }

    private var sidebarDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard viewModel.isSidebarVisible else { return }
                let horizontal = value.translation.width
                guard isSidebarCloseDragIntent(value) else {
                    sidebarDragOffset = 0
                    return
                }
                dismissKeyboard()
                sidebarDragOffset = min(0, horizontal)
            }
            .onEnded { value in
                guard viewModel.isSidebarVisible else { return }
                let predicted = value.predictedEndTranslation.width
                if isSidebarCloseDragIntent(value) && (value.translation.width < -80 || predicted < -150) {
                    closeSidebar()
                } else {
                    sidebarDragOffset = 0
                }
            }
    }

    private func openSidebarGesture(hiddenOffset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard !viewModel.isSidebarVisible else { return }
                let horizontal = value.translation.width
                let vertical = abs(value.translation.height)
                guard horizontal > 0, horizontal > vertical else { return }
                dismissKeyboard()
                sidebarDragOffset = min(-hiddenOffset, horizontal)
            }
            .onEnded { value in
                guard !viewModel.isSidebarVisible else { return }
                let predicted = value.predictedEndTranslation.width
                if value.translation.width > 72 || predicted > 150 {
                    dismissKeyboard()
                    viewModel.isSidebarVisible = true
                }
                sidebarDragOffset = 0
            }
    }

    private func edgeSwipeHotZone(height: CGFloat, hiddenOffset: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: edgeSwipeWidth, height: height)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(!viewModel.isSidebarVisible)
            .highPriorityGesture(openSidebarGesture(hiddenOffset: hiddenOffset))
            .zIndex(1)
    }

    private func isSidebarCloseDragIntent(_ value: DragGesture.Value) -> Bool {
        let horizontal = value.translation.width
        guard horizontal < -sidebarCloseIntentMinimum else { return false }
        let vertical = abs(value.translation.height)
        return abs(horizontal) >= max(sidebarCloseIntentMinimum, vertical * sidebarCloseIntentRatio)
    }

    private func closeSidebar() {
        sidebarDragOffset = 0
        viewModel.isSidebarVisible = false
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func copyAbsolutePath(_ entry: RemoteProjectFileEntry) {
        guard let path = viewModel.absolutePath(for: entry) else { return }
        UIPasteboard.general.string = path
        viewModel.insertPathIntoInput(path)
    }
}

#Preview {
    RootView()
}
