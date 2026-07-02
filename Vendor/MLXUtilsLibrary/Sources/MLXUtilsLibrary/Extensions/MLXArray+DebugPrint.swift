//
//  MLXUtilsLibrary
//
import Foundation
import MLX

extension MLXArray {
  #if DEBUG

  /// Pretty-prints an MLXArray with shape and a compact view of contents.
  /// - Parameters:
  ///   - x: The array to print.
  ///   - headRows: How many top rows to show (if 2-D or higher).
  ///   - tailRows: How many bottom rows to show (if 2-D or higher).
  ///   - headCols: How many leading columns to show per row.
  ///   - tailCols: How many trailing columns to show per row.
  ///   - precision: Significant digits for numbers.
  public func debugPrint(
    headRows: Int = 3,
    tailRows: Int = 2,
    headCols: Int = 6,
    tailCols: Int = 6,
    precision: Int = 4
  ) {
    let x = self
    
    let shape = x.shape  // e.g. [rows, cols]
    let total = shape.reduce(1, * )
    
    // Bring data to Swift as a flat [Float] for easy formatting.
    // (Safe for any dtype; we just view it as Float for printing.)
    let flat: [Float] = x.asType(Float.self).asArray(Float.self)
    
    func fmt(_ v: Float) -> String { String(format: "%.\(precision)g", v) }
    
    logPrint("MLXArray shape: \(shape)  count: \(total)")
    
    // 0-D (scalar)
    if shape.isEmpty {
      if let v = flat.first { logPrint("\(v)") } else { print("(empty)") }
      return
    }
    
    // Decide “rows × cols” for printing.
    // If 1-D: rows = 1, cols = count
    // If 2-D+: collapse leading dims into rows and use last dim as columns.
    let cols = shape.last ?? flat.count
    guard cols > 0 else { logPrint("[]"); return }
    let rows = Swift.max(1, flat.count / cols)
    
    // 1-D pretty print
    if shape.count == 1 {
      if cols <= headCols + tailCols {
        let line = flat.prefix(cols).map(fmt).joined(separator: ", ")
        logPrint("[\(line)]")
      } else {
        let head = flat.prefix(headCols).map(fmt).joined(separator: ", ")
        let tail = flat.suffix(tailCols).map(fmt).joined(separator: ", ")
        logPrint("[\(head), ..., \(tail)]")
      }
      return
    }
    
    // 2-D (or N-D viewed as 2-D) pretty print
    func rowString(_ r: Int) -> String {
      let start = r * cols
      let end = start + cols
      let row = flat[start..<end]
      if cols <= headCols + tailCols {
        return "[" + row.map(fmt).joined(separator: ", ") + "]"
      } else {
        let left = row.prefix(headCols).map(fmt).joined(separator: ", ")
        let right = row.suffix(tailCols).map(fmt).joined(separator: ", ")
        return "[" + left + ", ..., " + right + "]"
      }
    }
    
    logPrint("[")
    if rows <= headRows + tailRows {
      for r in 0..<rows {
        logPrint("  \(rowString(r))")
      }
    } else {
      for r in 0..<headRows { logPrint("  \(rowString(r))") }
      logPrint("  ...")
      for r in (rows - tailRows)..<rows { logPrint("  \(rowString(r))") }
    }
    logPrint("]")
  }

  #else

  /// No-op in RELEASE builds
  @inline(__always) public func debugPrint() {}

  #endif
}
