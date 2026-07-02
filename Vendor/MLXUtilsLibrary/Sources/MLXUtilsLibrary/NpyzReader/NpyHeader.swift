//
//  MLXUtilsLibrary
//
import Foundation

/// NumPy header metadata parser. Based on https://github.com/qoncept/swift-npy
/// Represents and parses the header section of a NumPy `.npy` file, which contains metadata
/// about the array including its shape, data type, endianness, and memory layout order.
struct NpyHeader {
  /// Errors that can occur during header parsing.
  enum NpyHeaderError: Error {
    /// The header data is invalid or malformed.
    case invalidHeader(reason: String)
  }
  
  /// Byte order (endianness) representation in NumPy format.
  enum Endian: String {
    /// Native/host byte order.
    case host = "="
    /// Big-endian byte order.
    case big = ">"
    /// Little-endian byte order.
    case little = "<"
    /// Not applicable (for single-byte types).
    case na = "|"
    
    /// Returns all endianness types.
    static var all: [Endian] {
      return [.host, .big, .little, .na]
    }
  }
  
  /// The shape of the array as an array of dimension sizes.
  let shape: [Int]
  /// The data type of array elements.
  let dataType: NpyDataType
  /// The byte order (endianness) of the data.
  let endian: Endian
  /// Whether the array is stored in Fortran (column-major) order.
  let isFortranOrder: Bool
  /// The raw descriptor string from the header.
  let descr: String
  
  /// The total number of elements in the array (product of all dimensions).
  var elementsCount: Int { shape.reduce(1, *) }
  
  /// Creates a new header with the specified properties.
  /// - Parameters:
  ///   - shape: The array shape.
  ///   - dataType: The data type of elements.
  ///   - endian: The byte order.
  ///   - isFortranOrder: Whether data is in Fortran order.
  ///   - descr: The raw descriptor string.
  private init(shape: [Int], dataType: NpyDataType, endian: Endian, isFortranOrder: Bool, descr: String) {
    self.shape = shape
    self.dataType = dataType
    self.endian = endian
    self.isFortranOrder = isFortranOrder
    self.descr = descr
  }
  
  /// Parses NumPy header data to extract array metadata.
  /// - Parameter data: The raw header data to parse.
  /// - Returns: A parsed `NpyHeader` instance containing the array metadata.
  /// - Throws: `NpyHeaderError.invalidHeader` if the header is malformed or contains unsupported values.
  static func parse(_ data: Data) throws -> NpyHeader {
    guard let str = String(data: data, encoding: .ascii) else {
      throw NpyHeaderError.invalidHeader(reason: "Header does not contain the key 'descr'")
    }
      
    let descr: String
    let endian: NpyHeader.Endian
    let dataType: NpyDataType
    let isFortranOrder: Bool
    var shape: [Int] = []

    let separate = str.components(separatedBy: CharacterSet(charactersIn: ", ")).filter { !$0.isEmpty }
    
    guard let descrIndex = separate.firstIndex(where: { $0.contains("descr") }) else {
      throw NpyHeaderError.invalidHeader(reason: "Header does not contain the key 'descr'")
    }
    descr = separate[descrIndex + 1]
    
    guard let e = NpyHeader.Endian.all.filter({ descr.contains($0.rawValue) }).first else {
      throw NpyHeaderError.invalidHeader(reason: "Unknown endian type")
    }
    endian = e
    
    guard let dt = NpyDataType.all.filter({ descr.contains($0.rawValue) }).first else {
      throw NpyHeaderError.invalidHeader(reason: "Unsupported dtype: \(descr)")
    }
    dataType = dt
    
    guard let fortranIndex = separate.firstIndex(where: { $0.contains("fortran_order") }) else {
      throw NpyHeaderError.invalidHeader(reason: "Header does not contain the key 'fortran_order'")
    }
    
    isFortranOrder = separate[fortranIndex + 1].contains("True")

    guard let left = str.range(of: "("), let right = str.range(of: ")") else {
      throw NpyHeaderError.invalidHeader(reason: "Shape not found in header")
    }
    
    let substr = str[left.upperBound..<right.lowerBound]
    
    let strs = substr.replacingOccurrences(of: " ", with: "")
      .components(separatedBy: ",")
      .filter { !$0.isEmpty }
  
    for s in strs {
      guard let i = Int(s) else {
        throw NpyHeaderError.invalidHeader(reason: "Shape contains invalid integer: \(s)")
      }
      shape.append(i)
    }
  
    return NpyHeader(
      shape: shape,
      dataType: dataType,
      endian: endian,
      isFortranOrder: isFortranOrder,
      descr: descr)
  }
}
