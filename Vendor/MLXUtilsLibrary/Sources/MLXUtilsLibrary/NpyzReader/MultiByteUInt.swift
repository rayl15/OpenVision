//
//  MLXUtilsLibrary
//
import Foundation

/// A protocol for unsigned integer types that can be initialized from big-endian or little-endian byte representations.
/// This protocol is used by the NPY/NPZ reader to abstract over different unsigned integer types
/// when reading binary data with specific byte orders. NPY files can store data in either big-endian
/// or little-endian format, and this protocol allows generic code to handle both cases.
///
/// The protocol leverages the existing `init(bigEndian:)` and `init(littleEndian:)` initializers
/// that are already provided by Swift's standard unsigned integer types.
protocol MultiByteUInt {
    /// Creates an integer from its big-endian representation, swapping bytes if necessary.
    /// - Parameter bigEndian: A value in big-endian byte order
    init(bigEndian: Self)
    
    /// Creates an integer from its little-endian representation, swapping bytes if necessary.
    /// - Parameter littleEndian: A value in little-endian byte order
    init(littleEndian: Self)
}

/// Conformance for 16-bit unsigned integers
extension UInt16: MultiByteUInt {}

/// Conformance for 32-bit unsigned integers
extension UInt32: MultiByteUInt {}

/// Conformance for 64-bit unsigned integers
extension UInt64: MultiByteUInt {}
