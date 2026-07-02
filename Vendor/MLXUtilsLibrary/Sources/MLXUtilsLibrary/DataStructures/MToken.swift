import Foundation
import NaturalLanguage

/// Additional metadata for tokens, storing linguistic and prosodic information.
public class Underscore {
  /// Indicates whether this token is the head of a phrase or syntactic unit.
  public var is_head: Bool
  /// An alternative representation or alias for the token (e.g., abbreviation expansion).
  public var alias: String?
  /// Stress level for pronunciation, typically used in text-to-speech systems.
  public var stress: Double?
  /// Currency type if the token represents a monetary value.
  public var currency: String?
  /// Flags related to numeric interpretation or formatting.
  public var num_flags: String
  /// Indicates whether whitespace should precede this token in output.
  public var prespace: Bool
  /// A quality or confidence rating for the token metadata.
  public var rating: Int?

  /// Creates a new instance with optional linguistic metadata.
  /// - Parameters:
  ///   - is_head: Whether this token is a phrase head (defaults to `true`).
  ///   - alias: Alternative representation (defaults to `nil`).
  ///   - stress: Stress level for pronunciation (defaults to `nil`).
  ///   - currency: Currency type for monetary values (defaults to `nil`).
  ///   - num_flags: Numeric interpretation flags (defaults to empty string).
  ///   - prespace: Whether to add preceding whitespace (defaults to `false`).
  ///   - rating: Quality or confidence rating (defaults to `nil`).
  public init(
    is_head: Bool = true,
    alias: String? = nil,
    stress: Double? = nil,
    currency: String? = nil,
    num_flags: String = "",
    prespace: Bool = false,
    rating: Int? = nil) {
      self.is_head = is_head
      self.alias = alias
      self.stress = stress
      self.currency = currency
      self.num_flags = num_flags
      self.prespace = prespace
      self.rating = rating
  }
  
  /// Creates a copy of an existing `Underscore` instance.
  /// - Parameter other: The `Underscore` instance to copy.
  convenience init(copying other: Underscore) {
    self.init(
      is_head: other.is_head,
      alias: other.alias,
      stress: other.stress,
      currency: other.currency,
      num_flags: other.num_flags,
      prespace: other.prespace,
      rating: other.rating)
  }
}

/// Extension providing a human-readable string representation.
extension Underscore: CustomStringConvertible {
  /// A textual representation of the `Underscore` instance showing all properties.
  public var description: String {
    let mirror = Mirror(reflecting: self)
    let props = mirror.children.compactMap { child -> String? in
      guard let label = child.label else { return nil }
      return "\(label): \(String(describing: child.value))"
    }.joined(separator: ", ")
    return "\(type(of: self))(\(props))"
  }
}

/// Represents a single linguistic token with associated metadata.
public class MToken {
  /// The text content of the token.
  public var text: String
  /// The character range of this token in the original string.
  public var tokenRange: Range<String.Index>
  /// The linguistic tag (e.g., part of speech) assigned by `NaturalLanguage` framework.
  public var tag: NLTag?
  /// Whitespace that follows this token in the original text.
  public var whitespace: String
  /// Phonetic representation of the token for pronunciation.
  public var phonemes: String?
  /// Start timestamp for audio alignment (in seconds).
  public var start_ts: Double?
  /// End timestamp for audio alignment (in seconds).
  public var end_ts: Double?
  /// Additional linguistic and prosodic metadata.
  public var `_`: Underscore
  
  /// Creates a new token with the specified properties.
  /// - Parameters:
  ///   - text: The token's text content.
  ///   - tokenRange: The character range in the original string.
  ///   - tag: Optional linguistic tag (e.g., noun, verb).
  ///   - whitespace: Whitespace following the token.
  ///   - phonemes: Optional phonetic representation.
  ///   - start_ts: Optional start timestamp in seconds.
  ///   - end_ts: Optional end timestamp in seconds.
  ///   - underscore: Additional metadata (defaults to a new `Underscore` instance).
  public init(
    text: String,
    tokenRange: Range<String.Index>,
    tag: NLTag? = nil,
    whitespace: String,
    phonemes: String? = nil,
    start_ts: Double? = nil,
    end_ts: Double? = nil,
    underscore: Underscore = Underscore()) {
      self.text = text
      self.tokenRange = tokenRange
      self.tag = tag
      self.whitespace = whitespace
      self.phonemes = phonemes
      self.start_ts = start_ts
      self.end_ts = end_ts
      self.`_` = underscore
    }
  
  /// Creates a deep copy of an existing `MToken` instance.
  /// - Parameter other: The `MToken` instance to copy.
  public convenience init(copying other: MToken) {
    self.init(
      text: other.text,
      tokenRange: other.tokenRange,
      tag: other.tag,
      whitespace: other.whitespace,
      phonemes: other.phonemes,
      start_ts: other.start_ts,
      end_ts: other.end_ts,
      underscore: Underscore(copying: other.`_`))
  }
}

/// Extension providing a human-readable string representation.
extension MToken : CustomStringConvertible {
  /// A textual representation of the `MToken` instance showing all properties.
  public var description: String {
    let mirror = Mirror(reflecting: self)
    let props = mirror.children.compactMap { child -> String? in
      guard let label = child.label else { return nil }
      return "\(label): \(String(describing: child.value))"
    }.joined(separator: ", ")
    return "\(type(of: self))(\(props))"
  }
}
