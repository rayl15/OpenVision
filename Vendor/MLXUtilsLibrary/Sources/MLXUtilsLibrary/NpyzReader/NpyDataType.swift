//
//  MLXUtilsLibrary
//
import Foundation

/// NumPy data type representations. Based on https://github.com/qoncept/swift-npy
/// This enum maps NumPy's type descriptor strings to Swift types. The raw values
/// correspond to NumPy's format strings where the letter indicates the type category
/// (b=boolean, u=unsigned int, i=signed int, f=float) and the number indicates byte size.
enum NpyDataType: String {
  /// Boolean type (1 byte).
  case bool = "b1"
  /// Unsigned 8-bit integer (1 byte).
  case uint8 = "u1"
  /// Unsigned 16-bit integer (2 bytes).
  case uint16 = "u2"
  /// Unsigned 32-bit integer (4 bytes).
  case uint32 = "u4"
  /// Unsigned 64-bit integer (8 bytes).
  case uint64 = "u8"
  /// Signed 8-bit integer (1 byte).
  case int8 = "i1"
  /// Signed 16-bit integer (2 bytes).
  case int16 = "i2"
  /// Signed 32-bit integer (4 bytes).
  case int32 = "i4"
  /// Signed 64-bit integer (8 bytes).
  case int64 = "i8"
  /// 32-bit floating-point (4 bytes).
  case float32 = "f4"
  /// 64-bit floating-point (8 bytes).
  case float64 = "f8"
  
  /// Returns all supported data types.
  static var all: [NpyDataType] {
    [.bool,
    .uint8, .uint16, .uint32, .uint64,
    .int8, .int16, .int32, .int64,
    .float32, .float64]
  }
}
