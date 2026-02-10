// OpenVision - GlassesCameraService.swift
// Camera service for Meta Ray-Ban glasses using DAT SDK

import UIKit
import MWDATCore
import MWDATCamera

/// Camera service for Meta Ray-Ban smart glasses
@MainActor
final class GlassesCameraService: NSObject, ObservableObject {
    // MARK: - Singleton

    static let shared = GlassesCameraService()

    // MARK: - Published State

    @Published var isStreaming = false
    @Published var lastFrame: UIImage?
    @Published var lastPhotoData: Data?
    @Published var streamFPS: Int = 0

    // MARK: - Callbacks

    var onVideoFrame: ((UIImage) -> Void)?
    var onPhotoCaptured: ((Data) -> Void)?

    // MARK: - Stream Configuration

    private var targetFPS: Int = 1

    // MARK: - DAT SDK References

    private var streamSession: StreamSession?
    private var deviceSelector: AutoDeviceSelector?
    private var stateListenerToken: (any AnyListenerToken)?
    private var videoFrameListenerToken: (any AnyListenerToken)?
    private var photoDataListenerToken: (any AnyListenerToken)?
    private var errorListenerToken: (any AnyListenerToken)?

    // MARK: - Frame Throttling

    private var lastFrameTime: Date = .distantPast
    private var frameCount: Int = 0
    private var fpsTimer: Timer?

    // MARK: - Initialization

    private override init() {
        super.init()
    }

    // MARK: - Streaming

    /// Start video streaming from glasses
    /// - Parameter fps: Target frames per second (1-30, clamped)
    func startStreaming(fps: Int = 1) async throws {
        guard !isStreaming else { return }

        targetFPS = max(1, min(30, fps))

        // Create device selector
        deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)

        guard let selector = deviceSelector else {
            throw CameraError.deviceUnavailable
        }

        // Configure stream session
        let config = StreamSessionConfig(
            videoCodec: .raw,
            resolution: .low,
            frameRate: 24
        )

        streamSession = StreamSession(
            streamSessionConfig: config,
            deviceSelector: selector
        )

        guard let session = streamSession else {
            throw CameraError.captureSessionFailed
        }

        // Set up listeners
        setupStreamListeners(session: session)

        // Start streaming
        await session.start()
        isStreaming = true
        startFPSCounter()

        print("[GlassesCamera] Started streaming at \(targetFPS) FPS target")
    }

    /// Stop video streaming
    func stopStreaming() async {
        guard isStreaming, let session = streamSession else { return }

        await session.stop()

        cleanupStreamListeners()
        streamSession = nil
        deviceSelector = nil
        isStreaming = false
        lastFrame = nil
        stopFPSCounter()

        print("[GlassesCamera] Stopped streaming")
    }

    // MARK: - Photo Capture

    /// Capture a single photo from glasses
    func capturePhoto() async throws -> Data? {
        guard isStreaming, let session = streamSession else {
            print("[GlassesCamera] No active stream session for photo capture")
            return nil
        }

        try await session.capturePhoto(format: .jpeg)

        // Wait for photo data via listener
        // The photo will be received via photoDataPublisher
        return lastPhotoData
    }

    // MARK: - Stream Listeners

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
                self?.processVideoFrame(frame)
            }
        }

        // Photo data listener
        photoDataListenerToken = session.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor in
                let data = photoData.data
                self?.lastPhotoData = data
                self?.onPhotoCaptured?(data)
                print("[GlassesCamera] Photo captured: \(data.count) bytes")
            }
        }

        // Error listener
        errorListenerToken = session.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                print("[GlassesCamera] Stream error: \(error)")
            }
        }
    }

    private func cleanupStreamListeners() {
        stateListenerToken = nil
        videoFrameListenerToken = nil
        photoDataListenerToken = nil
        errorListenerToken = nil
    }

    // MARK: - Frame Processing

    private func processVideoFrame(_ frame: VideoFrame) {
        // Throttle to target FPS
        let now = Date()
        let interval = 1.0 / Double(targetFPS)

        guard now.timeIntervalSince(lastFrameTime) >= interval else { return }
        lastFrameTime = now
        frameCount += 1

        // Convert to UIImage
        guard let image = frame.makeUIImage() else { return }

        lastFrame = image
        onVideoFrame?(image)
    }

    // MARK: - Image Processing

    /// Compress image to JPEG with quality and size constraints
    func compressToJPEG(_ image: UIImage, quality: CGFloat = 0.5, maxDimension: CGFloat = 512) -> Data? {
        let resized = resizeImage(image, maxDimension: maxDimension)
        return resized.jpegData(compressionQuality: quality)
    }

    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size

        guard size.width > maxDimension || size.height > maxDimension else {
            return image
        }

        let scale = maxDimension / max(size.width, size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return resized ?? image
    }

    // MARK: - FPS Counter

    private func startFPSCounter() {
        frameCount = 0
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.streamFPS = self?.frameCount ?? 0
                self?.frameCount = 0
            }
        }
    }

    private func stopFPSCounter() {
        fpsTimer?.invalidate()
        fpsTimer = nil
        streamFPS = 0
    }
}
