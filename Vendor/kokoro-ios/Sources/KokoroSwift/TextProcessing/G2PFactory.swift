//
//  KokoroSwift
//
import Foundation

/// Available grapheme-to-phoneme engines.
/// Engine availability depends on which optional dependencies are included at compile time.
public enum G2P {
  /// MisakiSwift-based G2P engine for English text.
  case misaki
  /// eSpeak NG-based G2P engine supporting multiple languages.
  case eSpeakNG
}

/// Factory class for creating G2P processor instances.
/// This factory provides a centralized way to instantiate G2P processors based on the
/// desired engine type, handling conditional compilation for optional dependencies.
final class G2PFactory {
  /// Errors that can occur during G2P processor creation.
  enum G2PError: Error {
    /// The requested G2P engine is not available (dependency not included at compile time).
    case noSuchEngine
  }
  
  /// This class can never be instantiated.
  private init() {}
  
  /// Creates a G2P processor instance for the specified engine.
  /// - Parameter engine: The type of G2P engine to create.
  /// - Returns: A configured G2P processor instance.
  /// - Throws: `G2PError.noSuchEngine` if the requested engine is not available at compile time.
  static func createG2PProcessor(engine: G2P) throws -> G2PProcessor {
    switch engine {
    
    case .misaki:
#if canImport(MisakiSwift)
      return MisakiG2PProcessor()
#else
      throw G2PError.noSuchEngine
#endif

    case .eSpeakNG:
#if canImport(eSpeakNGLib)
      return eSpeakNGG2PProcessor()
#else
      throw G2PError.noSuchEngine
#endif
    }
  }
}
