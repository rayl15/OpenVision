import Foundation

extension String {
  func replacingLastOccurrence(of target: Character, with replacement: Character) -> String {
    guard let lastIndex = self.lastIndex(of: target) else {
      return self
    }
    
    var result = self
    result.replaceSubrange(lastIndex...lastIndex, with: String(replacement))
    
    return result
  }
}
