@testable import SwitchboardCore

/// Inputs for timing a scan for many session ids.
enum ManySessions {
  static let prefixes = ["s", SessionID.prefix]

  /// `count` distinct ids of each form in the session id alphabet.
  static func ids(_ count: Int) -> [String] {
    prefixes.flatMap { prefix in
      let alphabet = Array(ShortId.alphabet)
      return (0..<count).map { i in
        var n = i
        var id = prefix
        for _ in 0..<ShortId.length {
          id.append(alphabet[n % alphabet.count])
          n /= alphabet.count
        }
        return id
      }
    }
  }

  static func names(_ ids: [String]) -> SessionNames {
    SessionNames(live: Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, "session-\($0)") }), removed: [:])
  }
}
