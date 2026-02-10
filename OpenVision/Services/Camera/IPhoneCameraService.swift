// OpenVision - IPhoneCameraService.swift
// iPhone camera fallback for testing without glasses

import AVFoundation
import UIKit

/// iPhone camera service for testing without glasses
@MainActor
final class IPhoneCameraService: NSObject, ObservableObject {
    // MARK: - Singleton

    static let shared = IPhoneCameraService()

    // MARK: - Published State

    @Published var isStreaming = false
    @Published var lastFrame: UIImage?
    @Published var lastPhotoData: Data?
    @Published var authorizationStatus: AVAuthorizationStatus = .notDetermined

    // MARK: - Callbacks

    var onVideoFrame: ((UIImage) -> Void)?
    var onPhotoCaptured: ((Data) -> Void)?

    // MARK: - Capture Session

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var photoOutput: AVCapturePhotoOutput?
    private let sessionQueue = DispatchQueue(label: "camera.session")

    // MARK: - Frame Throttling

    private var lastFrameTime: Date = .distantPast
    private var targetFPS: Int = 1

    // MARK: - Initialization

    private override init() {
        super.init()
        checkAuthorization()
    }

    // MARK: - Authorization

    /// Check camera authorization
    func checkAuthorization() {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Request camera authorization
    func requestAuthorization() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        await MainActor.run {
            authorizationStatus = granted ? .authorized : .denied
        }
        return granted
    }

    // MARK: - Streaming

    /// Start camera streaming
    func startStreaming(fps: Int = 1) throws {
        guard authorizationStatus == .authorized else {
            throw CameraError.notAuthorized
        }

        guard !isStreaming else { return }

        targetFPS = fps

        sessionQueue.async { [weak self] in
            self?.setupCaptureSession()
        }
    }

    /// Stop camera streaming
    func stopStreaming() {
        guard isStreaming else { return }

        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()

            Task { @MainActor in
                self?.isStreaming = false
                self?.lastFrame = nil
            }
        }

        print("[iPhoneCamera] Stopped streaming")
    }

    /// Setup capture session
    private func setupCaptureSession() {
        captureSession = AVCaptureSession()

        guard let session = captureSession else { return }

        session.beginConfiguration()
        session.sessionPreset = .medium

        // Add video input
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice) else {
            print("[iPhoneCamera] Failed to get video device")
            return
        }

        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
        }

        // Add video output
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            self.videoOutput = videoOutput
        }

        // Add photo output
        let photoOutput = AVCapturePhotoOutput()

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            self.photoOutput = photoOutput
        }

        session.commitConfiguration()
        session.startRunning()

        Task { @MainActor in
            self.isStreaming = true
        }

        print("[iPhoneCamera] Started streaming at \(targetFPS) FPS")
    }

    // MARK: - Photo Capture

    /// Capture a photo
    func capturePhoto() {
        guard let photoOutput = photoOutput, isStreaming else {
            print("[iPhoneCamera] Cannot capture - not streaming")
            return
        }

        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off

        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Frame Processing

    /// Process video frame
    private func processVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        // Throttle to target FPS
        let now = Date()
        let interval = 1.0 / Double(targetFPS)

        guard now.timeIntervalSince(lastFrameTime) >= interval else { return }
        lastFrameTime = now

        // Convert to UIImage
        guard let image = imageFromSampleBuffer(sampleBuffer) else { return }

        Task { @MainActor in
            self.lastFrame = image
            self.onVideoFrame?(image)
        }
    }

    /// Convert sample buffer to UIImage
    private func imageFromSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> UIImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    /// Compress image to JPEG
    func compressToJPEG(_ image: UIImage, quality: CGFloat = 0.5, maxDimension: CGFloat = 512) -> Data? {
        // Resize if needed
        let resized = resizeImage(image, maxDimension: maxDimension)

        // Compress
        return resized.jpegData(compressionQuality: quality)
    }

    /// Resize image maintaining aspect ratio
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
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension IPhoneCameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        Task { @MainActor in
            self.processVideoFrame(sampleBuffer)
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension IPhoneCameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil else {
            print("[iPhoneCamera] Photo capture error: \(error!)")
            return
        }

        guard let imageData = photo.fileDataRepresentation() else {
            print("[iPhoneCamera] Failed to get photo data")
            return
        }

        Task { @MainActor in
            // Compress the photo
            if let image = UIImage(data: imageData),
               let compressed = self.compressToJPEG(image) {
                self.lastPhotoData = compressed
                self.onPhotoCaptured?(compressed)
                print("[iPhoneCamera] Photo captured: \(compressed.count) bytes")
            }
        }
    }
}

// MARK: - Errors

enum CameraError: LocalizedError {
    case notAuthorized
    case deviceUnavailable
    case captureSessionFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Camera access not authorized"
        case .deviceUnavailable: return "Camera device unavailable"
        case .captureSessionFailed: return "Failed to setup camera"
        }
    }
}
