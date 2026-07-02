//
//  MLXUtilsLibrary
//
import Foundation

/// Extension providing data loading utilities for NpyContainer. Based on https://github.com/qoncept/swift-npy
/// These methods handle the low-level byte-to-value conversion, including endianness transformations,
/// required for parsing NumPy array data.
extension NpyContainer {
  /// Loads multi-byte unsigned integers from binary data with endianness conversion.
  /// Reads binary data and converts it to an array of unsigned integers, applying the appropriate
  /// endianness transformation based on the header specification.
  /// - Parameters:
  ///   - data: The raw binary data to read from.
  ///   - count: The number of elements to read.
  ///   - endian: The endianness of the data (host, big, little, or not applicable).
  /// - Returns: An array of unsigned integers of type `T`, or `nil` if endianness is not applicable.
  func loadUInts<T: MultiByteUInt>(data: Data, count: Int, endian: NpyHeader.Endian) -> [T]? {
    switch endian {
    case .host:
      let uints = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        buffer.bindMemory(to: T.self).prefix(count).map { $0 }
      }
      return uints
    case .big:
      return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        buffer.bindMemory(to: T.self).prefix(count).map { T(bigEndian: $0) }
      }
    case .little:
      return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        buffer.bindMemory(to: T.self).prefix(count).map { T(littleEndian: $0) }
      }
    case .na:
      return nil
    }
  }
  
  /// Loads 8-bit unsigned integers from binary data. This method reads binary data and converts it directly to
  /// an array of `UInt8` values. Since `UInt8` is a single byte, no endianness conversion is needed.
  /// - Parameters:
  ///   - data: The raw binary data to read from.
  ///   - count: The number of bytes to read.
  /// - Returns: An array of `UInt8` values.
  func loadUInt8s(data: Data, count: Int) -> [UInt8] {
    let uints = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
      Array(buffer.prefix(count))
    }
    return uints
  }
}
