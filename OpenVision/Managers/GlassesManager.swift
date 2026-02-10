// OpenVision - GlassesManager.swift
// Singleton manager for Meta Ray-Ban glasses via DAT SDK

import Foundation
import SwiftUI
import MWDATCore
import MWDATCamera

/// Manages Meta Ray-Ban glasses registration, connection, and camera streaming
@MainActor
final class GlassesManager: ObservableObject {
    // MARK: - Singleton

    static let shared = GlassesManager()

    // MARK: - Published Properties

    /// Whether the app is registered with Meta AI
    @Published var isRegistered: Bool = false

    /// Currently connected device identifier
    @Published var connectedDevice: DeviceIdentifier?

    /// Number of connected devices
    @Published var connectedDeviceCount: Int = 0

    /// Whether camera streaming is active
    @Published var isStreaming: Bool = false

    /// Last captured video frame
    @Published var lastFrame: UIImage?

    /// Last captured photo data
    @Published var lastPhotoData: Data?

    /// Error message for UI display
    @Published var errorMessage: String?

    // MARK: - Private Properties

    private let wearables = Wearables.shared
    private var streamSession: StreamSession?

    // Listener tokens (retained to keep subscriptions active)
    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var stateListenerToken: (any AnyListenerToken)?
    private var videoFrameListenerToken: (any AnyListenerToken)?
    private var photoDataListenerToken: (any AnyListenerToken)?
    private var errorListenerToken: (any AnyListenerToken)?

    // MARK: - Callbacks

    /// Called when a video frame is received
    var onVideoFrame: ((UIImage) -> Void)?

    /// Called when a photo is captured
    var onPhotoCaptured: ((Data) -> Void)?

    // MARK: - Initialization

    private init() {
        print("[GlassesManager] Initializing")
        setupRegistrationListener()
        setupDevicesListener()
    }

    // MARK: - Registration

    /// Register app with Meta AI
    func register() async throws {
        print("[GlassesManager] Starting registration")

        // Check if already registered
        for await state in wearables.registrationStateStream() {
            if case .registered = state {
                print("[GlassesManager] Already registered")
                isRegistered = true
                return
            }
            break
        }

        // Start registration flow
        try await wearables.startRegistration()
        print("[GlassesManager] Registration initiated, waiting for Meta AI callback")
    }

    // MARK: - Streaming

    /// Start camera streaming from glasses
    func startStreaming() async {
        guard isRegistered else {
            errorMessage = "Not registered with Meta AI"
            print("[GlassesManager] Cannot start streaming - not registered")
            return
        }

        guard !isStreaming else {
            print("[GlassesManager] Already streaming")
            return
        }

        // Check for connected device
        guard let deviceId = connectedDevice else {
            errorMessage = "No glasses connected"
            print("[GlassesManager] Cannot start streaming - no device connected")
            return
        }

        print("[GlassesManager] Starting camera stream for device: \(deviceId)")

        // Request camera permission first (like xmeta does)
        do {
            var status = try await wearables.checkPermissionStatus(.camera)
            print("[GlassesManager] Camera permission status: \(status)")

            if status != .granted {
                print("[GlassesManager] Requesting camera permission...")
                status = try await wearables.requestPermission(.camera)
                print("[GlassesManager] After request, status: \(status)")
            }

            guard status == .granted else {
                errorMessage = "Camera permission denied"
                print("[GlassesManager] Camera permission not granted")
                return
            }
        } catch {
            errorMessage = "Permission error: \(error.localizedDescription)"
            print("[GlassesManager] Permission error: \(error)")
            return
        }

        // Use SpecificDeviceSelector like xmeta does (more reliable than AutoDeviceSelector)
        let specificSelector = SpecificDeviceSelector(device: deviceId)

        // Configure stream session
        let config = StreamSessionConfig(
            videoCodec: .raw,
            resolution: .medium,  // Medium resolution like xmeta
            frameRate: 30         // 30fps like xmeta
        )

        streamSession = StreamSession(
            streamSessionConfig: config,
            deviceSelector: specificSelector
        )

        guard let session = streamSession else {
            errorMessage = "Failed to create stream session"
            print("[GlassesManager] Failed to create stream session")
            return
        }

        // Set up listeners
        setupStreamListeners(session: session)

        // Start streaming
        print("[GlassesManager] Starting stream session...")
        await session.start()
        isStreaming = true
        print("[GlassesManager] Streaming started successfully")
    }

    /// Stop camera streaming
    func stopStreaming() async {
        guard isStreaming, let session = streamSession else { return }

        print("[GlassesManager] Stopping camera stream")

        await session.stop()

        cleanupStreamListeners()
        streamSession = nil
        isStreaming = false
        lastFrame = nil

        print("[GlassesManager] Streaming stopped")
    }

    /// Capture a photo from the glasses camera
    func capturePhoto() async {
        guard isStreaming, let session = streamSession else {
            errorMessage = "Streaming must be active to capture photos"
            return
        }

        print("[GlassesManager] Capturing photo")

        do {
            try await session.capturePhoto(format: .jpeg)
        } catch {
            errorMessage = "Failed to capture photo: \(error.localizedDescription)"
            print("[GlassesManager] Photo capture error: \(error)")
        }
    }

    // MARK: - Private Methods

    private func setupRegistrationListener() {
        registrationTask = Task {
            for await state in wearables.registrationStateStream() {
                await MainActor.run {
                    if case .registered = state {
                        self.isRegistered = true
                        print("[GlassesManager] Registration state: registered")
                    } else {
                        self.isRegistered = false
                        print("[GlassesManager] Registration state: \(state)")
                    }
                }
            }
        }
    }

    private func setupDevicesListener() {
        devicesTask = Task {
            for await devices in wearables.devicesStream() {
                await MainActor.run {
                    self.connectedDeviceCount = devices.count
                    self.connectedDevice = devices.first
                    print("[GlassesManager] Devices updated: \(devices.count) connected")
                }
            }
        }
    }

    private func setupStreamListeners(session: StreamSession) {
        // State listener
        stateListenerToken = session.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                switch state {
                case .streaming:
                    self?.isStreaming = true
                case .stopped:
                    self?.isStreaming = false
                default:
                    break
                }
            }
        }

        // Video frame listener
        videoFrameListenerToken = session.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor in
                if let image = frame.makeUIImage() {
                    self?.lastFrame = image
                    self?.onVideoFrame?(image)
                }
            }
        }

        // Photo data listener
        photoDataListenerToken = session.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor in
                let data = photoData.data
                self?.lastPhotoData = data
                self?.onPhotoCaptured?(data)
                print("[GlassesManager] Photo captured: \(data.count) bytes")
            }
        }

        // Error listener
        errorListenerToken = session.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error.localizedDescription
                print("[GlassesManager] Stream error: \(error)")
            }
        }
    }

    private func cleanupStreamListeners() {
        stateListenerToken = nil
        videoFrameListenerToken = nil
        photoDataListenerToken = nil
        errorListenerToken = nil
    }
}
