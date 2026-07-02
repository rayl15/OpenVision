//
//  Kokoro-tts-lib
//
import Foundation

/// Utility class for tokenizing the phonemized text.
/// Phonemize the text first before calling this method.
/// Returns tokenized array that can then be passed to TTS system.
final class Tokenizer {
  /// Private constructor to prevent instantiation.
  private init() {}

  /// Tokenize the phonemized text.
  /// - Parameters:
  ///   - phonemizedText: Phonemized text to tokenize
  /// - Returns: Tokenized array that can then be passed to TTS system
  static func tokenize(phonemizedText text: String) -> [Int] {
    guard let vocab = KokoroConfig.config?.vocab else { return [] }
    return text
      .map { vocab[String($0)] }
      .filter { $0 != nil }
      .map { $0! }
  }
}
