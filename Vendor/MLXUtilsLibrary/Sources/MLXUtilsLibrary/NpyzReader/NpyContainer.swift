//
//  MLXUtilsLibrary
//
import Foundation
import MLX

/// A container for parsing NumPy `.npy` file format data. Based on https://github.com/qoncept/swift-npy
/// `NpyContainer` provides functionality to read and parse binary data from NumPy's `.npy` file format,
/// extracting both the header information and array data. It supports conversion to MLX arrays and
/// extraction of elements as Swift native types.
struct NpyContainer {
  /// The magic prefix bytes that identify a valid NumPy `.npy` file.
  static let MAGIC_PREFIX = Data([0x93]) + "NUMPY".data(using: .ascii)!
    
  /// Errors that can occur during NumPy container parsing.
  enum NpyContainerError: Error {
    /// The container data is invalid.
    case invalidContainer(reason: String)
  }
  
  /// The parsed header information containing metadata about the array (shape, data type, endianness, etc.).
  let header: NpyHeader
  
  /// The raw binary data containing the array elements.
  let elementsData: Data

  /// Creates a new container with the given header and element data.
  /// - Parameters:
  ///   - header: The parsed NumPy header.
  ///   - elementsData: The raw binary data containing the array elements.
  private init(header: NpyHeader, elementsData: Data) {
    self.header = header
    self.elementsData = elementsData
  }
  
  /// Parses raw NumPy `.npy` file data into a container.
  /// This method validates the file, parses the header, and extracts the array element data.
  /// - Parameter data: The complete `.npy` file data to parse.
  /// - Returns: A new `NpyContainer` instance containing the parsed header and element data.
  /// - Throws: `NpyContainerError.invalidContainer` if the data format is invalid.
  static func parse(data: Data) throws -> NpyContainer {
    let magic = data.subdata(in: 0..<6)
    guard magic == MAGIC_PREFIX else {
      throw NpyContainerError.invalidContainer(reason: "Invalid prefix: \(magic)")
    }
    
    let major = data[6]
    guard major == 1 || major == 2 else {
      throw NpyContainerError.invalidContainer(reason: "Invalid major version: \(major)")
    }
    
    let minor = data[7]
    guard minor == 0 else {
      throw NpyContainerError.invalidContainer(reason: "Invalid minor version: \(minor)")
    }
    
    let headerLen: Int
    let rest: Data
    switch major {
    case 1:
      let tmp: UInt16 = data.withUnsafeBytes { rawBuf in
        rawBuf.load(fromByteOffset: 8, as: UInt16.self)
      }
      headerLen = Int(UInt16(littleEndian: tmp))
      rest = data.subdata(in: 10..<data.count)
    case 2:
      let tmp: UInt32 = data.withUnsafeBytes { rawBuf in
        rawBuf.load(fromByteOffset: 8, as: UInt32.self)
      }
      headerLen = Int(tmp)
      rest = data.subdata(in: 12..<data.count)
    default:
      fatalError("Never happens.")
    }
    
    let headerData = rest.subdata(in: 0..<headerLen)
    let header = try NpyHeader.parse(headerData)    
    let elementsData = rest.subdata(in: headerLen..<rest.count)
        
    return NpyContainer(header: header, elementsData: elementsData)
  }
}

// MARK: - Element Extraction
extension NpyContainer {
  /// Extracts array elements as Boolean values.
  /// - Parameter type: The target type (defaults to `Bool.self`).
  /// - Returns: An array of Boolean values.
  func elements(_ type: Bool.Type = Bool.self) -> [Bool] {
    let uints = loadUInt8s(data: elementsData, count: header.elementsCount)
    return uints.map { $0 != 0 }
  }
    
  /// Extracts array elements as 32-bit floating-point values.
  /// - Parameter type: The target type (defaults to `Float.self`).
  /// - Returns: An array of `Float` values, or an empty array if parsing fails.
  func elements(_ type: Float.Type = Float.self) -> [Float] {
    let uints: [UInt32]? = loadUInts(data: elementsData, count: header.elementsCount, endian: header.endian)
    guard let uints else { return [] }
    return uints.map { Float(bitPattern: $0) }
  }
  
  /// Extracts array elements as 64-bit floating-point values.
  /// - Parameter type: The target type (defaults to `Double.self`).
  /// - Returns: An array of `Double` values, or an empty array if parsing fails.
  func elements(_ type: Double.Type = Double.self) -> [Double] {
    let uints: [UInt64]? = loadUInts(data: elementsData, count: header.elementsCount, endian: header.endian)
    guard let uints else { return [] }
    return uints.map { Double(bitPattern: $0) }
  }
  
  /// Extracts array elements as unsigned 8-bit integer values.
  /// - Parameter type: The target type (defaults to `UInt8.self`).
  /// - Returns: An array of `UInt8` values.
  func elements(_ type: UInt8.Type = UInt8.self) -> [UInt8] {
    let uints = loadUInt8s(data: elementsData, count: header.elementsCount)
    return uints
  }
      
  /// Extracts array elements as unsigned 16-bit integer values.
  /// - Parameter type: The target type (defaults to `UInt16.self`).
  /// - Returns: An array of `UInt16` values, or an empty array if parsing fails.
  func elements(_ type: UInt16.Type = UInt16.self) -> [UInt16] {
    let uints: [UInt16]? = loadUInts(data: elementsData, count: header.elementsCount, endian: header.endian)
    guard let uints else { return [] }
    return uints
  }
      
  /// Extracts array elements as unsigned 32-bit integer values.
  /// - Parameter type: The target type (defaults to `UInt32.self`).
  /// - Returns: An array of `UInt32` values, or an empty array if parsing fails.
  func elements(_ type: UInt32.Type = UInt32.self) -> [UInt32] {
    let uints: [UInt32]? = loadUInts(data: elementsData, count: header.elementsCount, endian: header.endian)
    guard let uints else { return [] }
    return uints
  }
  
  /// Extracts array elements as unsigned 64-bit integer values.
  /// - Parameter type: The target type (defaults to `UInt64.self`).
  /// - Returns: An array of `UInt64` values, or an empty array if parsing fails.
  func elements(_ type: UInt64.Type = UInt64.self) -> [UInt64] {
    let uints: [UInt64]? = loadUInts(data: elementsData, count: header.elementsCount, endian: header.endian)
    guard let uints else { return [] }
    return uints
  }
  
  /// Extracts array elements as signed 8-bit integer values.
  /// - Parameter type: The target type (defaults to `Int8.self`).
  /// - Returns: An array of `Int8` values.
  func elements(_ type: Int8.Type = Int8.self) -> [Int8] {
    let uints = loadUInt8s(data: elementsData, count: header.elementsCount)
    return uints.map { Int8(bitPattern: $0) }
  }
      
  /// Extracts array elements as signed 16-bit integer values.
  /// - Parameter type: The target type (defaults to `Int16.self`).
  /// - Returns: An array of `Int16` values, or an empty array if parsing fails.
  func elements(_ type: Int16.Type = Int16.self) -> [Int16] {
    let uints: [UInt16]? = loadUInts(data: elementsData, count: header.elementsCount, endian: header.endian)
    guard let uints else { return [] }
    return uints.map { Int16(bitPattern: $0) }
  }
      
  /// Extracts array elements as signed 32-bit integer values.
  /// - Parameter type: The target type (defaults to `Int32.self`).
  /// - Returns: An array of `Int32` values, or an empty array if parsing fails.
  func elements(_ type: Int32.Type = Int32.self) -> [Int32] {
    let uints: [UInt32]? = loadUInts(data: elementsData, count: header.elementsCount, endian: header.endian)
    guard let uints else { return [] }
    return uints.map { Int32(bitPattern: $0) }
  }
      
  /// Extracts array elements as signed 64-bit integer values.
  /// - Parameter type: The target type (defaults to `Int64.self`).
  /// - Returns: An array of `Int64` values, or an empty array if parsing fails.
  func elements(_ type: Int64.Type = Int64.self) -> [Int64] {
    let uints: [UInt64]? = loadUInts(data: elementsData, count: header.elementsCount, endian: header.endian)
    guard let uints else { return [] }
    return uints.map { Int64(bitPattern: $0) }
  }
  
  /// Converts the NumPy array data to an MLX array. Automatically determines the appropriate
  /// data type based on the header and creates an `MLXArray` with the correct shape and values.
  /// - Returns: An `MLXArray` containing the parsed data with the shape specified in the header.
  func mlxArray() -> MLXArray {
    switch header.dataType {
    case .bool:
      return MLXArray([Bool](elements()), header.shape)
    case .int8:
      return MLXArray([Int8](elements()), header.shape)
    case .int16:
      return MLXArray([Int16](elements()), header.shape)
    case .int32:
      return MLXArray([Int32](elements()), header.shape)
    case .int64:
      return MLXArray([Int64](elements()), header.shape)
    case .uint8:
      return MLXArray([UInt8](elements()), header.shape)
    case .uint16:
      return MLXArray([UInt16](elements()), header.shape)
    case .uint32:
      return MLXArray([UInt32](elements()), header.shape)
    case .uint64:
      return MLXArray([UInt64](elements()), header.shape)
    case .float32:
      return MLXArray([Float](elements()), header.shape)
    case .float64:
      return MLXArray([Double](elements()), header.shape)
    }
  }
}
