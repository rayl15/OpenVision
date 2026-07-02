//
//  Kokoro-tts-lib
//
import AVFoundation
import Foundation

#if DEBUG

/// Debug helper class for audio file operations.
/// Provides method for writing synthesized audio to WAV files,
/// which is useful for debugging and testing the TTS pipeline.
///
/// - Note: This class is only available in DEBUG builds.
///
/// Example usage:
/// ```swift
/// let audioSamples: [Float] = try tts.generateAudio(...)
/// try AudioUtils.writeWavFile(
///     samples: audioSamples,
///     sampleRate: 24000,
///     fileURL: URL(fileURLWithPath: "output.wav")
/// )
/// ```
public final class AudioUtils {
  /// Errors that can occur during audio file operations.
  enum AudioUtilsErrors: Error {
    /// Thrown when unable to create an AVAudioFormat with the specified parameters
    case cannotCreateAVAudioFormat
  }
  
  /// AudioUtils is a utility class with only static methods and should not be instantiated.
  private init() {}
  
  /// Writes audio samples to a WAV file. Takes raw audio samples and writes them to disk as a WAV file
  /// using the specified sample rate. The output is mono (single channel) audio in 32-bit floating-point PCM format.
  /// - Parameters:
  ///   - samples: Array of audio samples as floating-point values (typically in range [-1.0, 1.0])
  ///   - sampleRate: Sample rate in Hz (e.g., 24000, 44100, 48000)
  ///   - fileURL: Destination URL where the WAV file should be written
  /// - Throws:
  ///   - `AudioUtilsErrors.cannotCreateAVAudioFormat` if audio format creation fails
  ///   - `AVAudioFile` errors if file writing fails
  public static func writeWavFile(samples: [Float], sampleRate: Double, fileURL: URL) throws {
    let frameCount = AVAudioFrameCount(samples.count)

    // Create audio format: mono, 32-bit float PCM
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: 1,
      interleaved: false
    ),
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: frameCount
    )
    else {
      throw AudioUtilsErrors.cannotCreateAVAudioFormat
    }

    // Set buffer length and copy samples
    buffer.frameLength = frameCount
    let channelData = buffer.floatChannelData![0]
    
    for i in 0 ..< Int(frameCount) {
      channelData[i] = samples[i]
    }

    // Create and write audio file
    let audioFile = try AVAudioFile(
      forWriting: fileURL,
      settings: format.settings,
      commonFormat: format.commonFormat,
      interleaved: format.isInterleaved
    )

    try audioFile.write(from: buffer)
  }
}

#endif
