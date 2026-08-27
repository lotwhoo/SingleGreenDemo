import AVFoundation
import SwiftUI
import UIKit

enum CameraAuthorizationState: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable

    var title: String {
        switch self {
        case .notDetermined: "等待相机权限"
        case .authorized: "相机已授权"
        case .denied: "无法访问相机"
        case .restricted: "相机受到系统限制"
        case .unavailable: "后置相机不可用"
        }
    }

    var message: String {
        switch self {
        case .notDetermined: "允许访问后置相机后，可在真实环境上预览单绿 HUD。"
        case .authorized: "正在准备后置相机。"
        case .denied: "请在系统设置中允许相机权限。当前仍可使用替代背景测试 HUD。"
        case .restricted: "当前设备策略限制了相机。仍可使用替代背景测试 HUD。"
        case .unavailable: "未找到可用后置相机。仍可使用替代背景测试 HUD。"
        }
    }

    var systemImage: String {
        switch self {
        case .notDetermined: "camera"
        case .authorized: "camera.fill"
        case .denied: "camera.fill.badge.ellipsis"
        case .restricted: "lock.trianglebadge.exclamationmark"
        case .unavailable: "camera.fill.badge.xmark"
        }
    }
}

@MainActor
final class CameraSessionController: NSObject, ObservableObject {
    @Published private(set) var authorizationState: CameraAuthorizationState
    @Published private(set) var isConfigured = false
    @Published private(set) var isPreparing = false
    @Published private(set) var startupDuration: TimeInterval?

    let session: AVCaptureSession
    private let pipeline: CameraSessionPipeline
    private let initializationUptime = ProcessInfo.processInfo.systemUptime

    override init() {
        let pipeline = CameraSessionPipeline()
        self.pipeline = pipeline
        session = pipeline.session
        authorizationState = Self.mapAuthorizationStatus(
            AVCaptureDevice.authorizationStatus(for: .video)
        )
        super.init()
    }

    func prepare() async {
        guard !isPreparing else { return }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        authorizationState = Self.mapAuthorizationStatus(status)

        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorizationState = granted ? .authorized : .denied
        }

        guard authorizationState == .authorized else { return }
        isPreparing = true

        let result = await pipeline.prepareAndStart()
        isPreparing = false

        switch result {
        case .ready:
            isConfigured = true
            if startupDuration == nil {
                startupDuration = ProcessInfo.processInfo.systemUptime - initializationUptime
            }
        case .unavailable:
            isConfigured = false
            authorizationState = .unavailable
        }
    }

    func handle(scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            if authorizationState == .authorized {
                if isConfigured {
                    pipeline.setRunning(true)
                } else if !isPreparing {
                    Task { await prepare() }
                }
            }
        case .inactive, .background:
            pipeline.setRunning(false)
        @unknown default:
            break
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private static func mapAuthorizationStatus(
        _ status: AVAuthorizationStatus
    ) -> CameraAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unavailable
        }
    }
}

private enum CameraSessionPreparationResult: Sendable {
    case ready
    case unavailable
}

private final class CameraSessionPipeline: @unchecked Sendable {
    let session = AVCaptureSession()

    private let queue = DispatchQueue(
        label: "com.local.SingleGreenDemo.camera",
        qos: .userInitiated
    )
    private var isConfigured = false

    func prepareAndStart() async -> CameraSessionPreparationResult {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .unavailable)
                    return
                }

                guard configureIfNeeded() else {
                    continuation.resume(returning: .unavailable)
                    return
                }

                if !session.isRunning {
                    session.startRunning()
                }
                continuation.resume(returning: .ready)
            }
        }
    }

    func setRunning(_ shouldRun: Bool) {
        queue.async { [weak self] in
            guard let self, isConfigured else { return }

            if shouldRun, !session.isRunning {
                session.startRunning()
            } else if !shouldRun, session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configureIfNeeded() -> Bool {
        guard !isConfigured else { return true }

        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ), let input = try? AVCaptureDeviceInput(device: camera) else {
            return false
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }

        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        isConfigured = true
        return true
    }
}
