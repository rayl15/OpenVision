import Foundation
import NaturalLanguage

extension NLTag {
  var isProperNoun: Bool {
    return self == .personalName || self == .organizationName || self == .placeName
  }
}
