//
//  MLXUtilsLibrary
//
import Foundation

#if DEBUG

/// Lightweight wrapper around Swift's `print()` function that only
/// executes in DEBUG builds. In RELEASE builds, this function becomes a no-op
/// with zero runtime overhead, ensuring that no log statements affect production
/// performance or binary size.
///
/// **Thread Safety:** This function is thread-safe as it relies on Swift's `print()`,
/// which handles concurrent access internally.
///
/// - Parameter s: The string to print to the console
@inline(__always) public func logPrint(_ s: String) {
  print(s)
}

#else

/// No-op in RELEASE builds
@inline(__always) public func logPrint(_ s: String) {}

#endif
