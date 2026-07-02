//
//  MLXUtilsLibrary
//
import Foundation
import MLX
import ZIPFoundation

/// A reader for NumPy `.npy` and `.npz` file formats. Based on https://github.com/qoncept/swift-npy
/// `NpyzReader` provides static methods to load NumPy arrays from both single `.npy` files and
/// compressed `.npz` archives (which contain multiple `.npy` files). The arrays are converted to MLX arrays..
public final class NpyzReader {
  /// Private constructor, this class should never be instantiated.
  private init() {}
  
  /// Unarchives a ZIP-compressed `.npz` file into a dictionary of array names to raw data.
  /// - Parameter data: The compressed `.npz` file data.
  /// - Returns: A dictionary mapping array names to their raw `.npy` data, or `nil` if extraction fails.
  private static func unarchive(data: Data) -> [String: Data]? {
    // Initialize an archive from in-memory data
    guard let archive = try? Archive(data: data, accessMode: .read, pathEncoding: nil) else {
      logPrint("Could not unzip the npyz archive")
      return nil
    }

    var result: [String: Data] = [:]
    for entry in archive {
      // Skip directories and symlinks, should not be any in .npyz formatted archives anyway
      guard entry.type == .file else { continue }

      var fileData = Data()
      fileData.reserveCapacity(Int(entry.uncompressedSize))

      // Stream the bytes into our Data buffer
      do {
        _ = try archive.extract(entry, skipCRC32: true) { chunk in
          fileData.append(chunk)
        }
        result[entry.path] = fileData
      } catch {
        logPrint("Could not extract \(entry.path) from the npyz archive")
      }
    }

    return result
  }
  
  /// Reads NumPy array data and converts it to MLX arrays.
  /// This method can handle both single `.npy` files and `.npz` archives containing multiple arrays.
  /// - Parameters:
  ///   - data: The raw file data (either `.npy` or `.npz` format).
  ///   - isPacked: Whether the data is a `.npz` archive (defaults to `false`).
  ///   - name: The name to use for a single array when `isPacked` is `false` (defaults to "npy").
  /// - Returns: A dictionary mapping array names to `MLXArray` instances, or `nil` if reading fails.
  public static func read(data: Data, isPacked: Bool = false, name: String = "npy") -> [String: MLXArray]? {
    guard let arraysToUnpack = isPacked ? unarchive(data: data) : [name: data] else {
      return nil
    }
    
    var output: [String: MLXArray] = [:]
    for (name, data) in arraysToUnpack {
      do {
        let container = try NpyContainer.parse(data: data)
        output[name] = container.mlxArray()
        logPrint("\(name): Array shaped \(output[name]!.shape)")
      } catch {
        logPrint("Could not parse the npy data")
      }
    }
            
    return output
  }
  
  /// Reads NumPy arrays from a file path and converts them to MLX arrays.
  /// This method loads data from a file URL and automatically determines whether it's a `.npz`
  /// archive based on the file extension (unless explicitly specified).
  /// - Parameters:
  ///   - path: The file URL to read from (must be a file URL, not a remote URL).
  ///   - isPacked: Whether the file is a `.npz` archive. If `nil`, determined automatically from the file extension.
  /// - Returns: A dictionary mapping array names to `MLXArray` instances, or `nil` if reading fails.
  public static func read(fileFromPath path: URL, isPacked: Bool? = nil) -> [String : MLXArray]? {
    guard path.isFileURL, let data = try? Data(contentsOf: path) else {
      return nil
    }
    
    let packed = isPacked == nil ? path.pathExtension.lowercased() == "npz" : isPacked!
    return read(data: data, isPacked: packed, name: path.lastPathComponent)
  }
}
