import SwiftUI
import AVFoundation
import UIKit

/// 扫码配对页（§6）：AVFoundation 内置 QR 扫描，无新依赖。
///
/// 权限四态：未决定→弹系统授权；已拒绝→引导去设置；受限/无相机（模拟器）
/// → 提示文案。扫到 `acode://pair?d=…` 回传一次即停（dedupe 防连发）。
struct QRScannerView: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var permissionState: PermissionState = .checking

    private enum PermissionState {
        case checking
        case authorized
        case denied
        case unavailable
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch permissionState {
                case .checking:
                    ProgressView()
                        .tint(.white)
                case .authorized:
                    ScannerRepresentable { code in
                        dismiss()
                        onCode(code)
                    }
                    .ignoresSafeArea()
                    VStack {
                        Spacer()
                        Text(L10n.key("对准电脑端设置页显示的配对二维码"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(.bottom, 40)
                    }
                case .denied:
                    permissionFallback(
                        icon: "camera.fill",
                        text: L10n.string("相机权限被拒绝，请在系统设置中允许 acode 使用相机。"),
                        showsSettingsButton: true
                    )
                case .unavailable:
                    permissionFallback(
                        icon: "camera.fill",
                        text: L10n.string("当前设备不可用相机。"),
                        showsSettingsButton: false
                    )
                }
            }
            .navigationTitle(L10n.key("扫码配对"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .codevokeTopBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(L10n.string("取消"))
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .task { await checkPermission() }
    }

    private func permissionFallback(icon: String, text: String, showsSettingsButton: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if showsSettingsButton {
                Button(L10n.string("去设置")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(.white.opacity(0.2), in: Capsule())
                .frame(minHeight: 44)
            }
        }
    }

    @MainActor
    private func checkPermission() async {
        guard AVCaptureDevice.default(for: .video) != nil else {
            permissionState = .unavailable
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionState = .authorized
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permissionState = granted ? .authorized : .denied
        case .denied, .restricted:
            permissionState = .denied
        @unknown default:
            permissionState = .denied
        }
    }
}

private struct ScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: ScannerViewController, coordinator: ()) {
        uiViewController.stopSession()
    }
}

/// AVCaptureSession 配置/启停放串行队列，previewLayer 跟随 view 布局更新。
private final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.codevoke.qr-scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didFire = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview
        sessionQueue.async { [weak self] in
            self?.configureSession()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didFire,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue, !value.isEmpty else { return }
        didFire = true
        onCode?(value)
    }
}
