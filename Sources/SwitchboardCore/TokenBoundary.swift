/// The rules that decide whether a token found in text stands on its own or is part of a longer word, path, or URL.
enum TokenBoundary {
  /// A letter, digit, or combining mark joins the token to a longer word.
  static func isWordScalar(_ c: Unicode.Scalar) -> Bool {
    switch c.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
      .decimalNumber, .letterNumber, .otherNumber,
      .nonspacingMark, .spacingMark, .enclosingMark:
      true
    default: false
    }
  }

  private static let forbiddenBefore: Set<Unicode.Scalar> = [
    "_", "-", "/", "\\", "@", ":", ".", "#", "$", "=", "~", "&", "%", "+",
  ]
  private static let forbiddenAfter: Set<Unicode.Scalar> = [
    "_", "-", "/", "\\", "@", "=", "#", "$", "%", "+", "~", "&",
  ]

  /// Whether a token may start right after `c`.
  static func allowedBefore(_ c: Unicode.Scalar) -> Bool { !isWordScalar(c) && !forbiddenBefore.contains(c) }

  private static let closing: Set<Unicode.Scalar> = [")", "]", "\"", "'", "\u{2019}", "\u{201D}"]

  /// Whether a token may end right before `s[i]`. A `.` or `:` ends a clause
  /// only when the text ends or whitespace or a closing mark follows it. So
  /// `seb4ec.jsonl`, `seb4ec:/tmp`, and `seb4ec._x` do not match. A run of
  /// dots counts as one `.`, as in `seb4ec...`.
  static func allowedAfter(_ i: Int, _ s: [Unicode.Scalar]) -> Bool {
    guard i < s.count else { return true }
    let c = s[i]
    if c == "." || c == ":" {
      var next = i + 1
      if c == "." { while next < s.count, s[next] == "." { next += 1 } }
      return next == s.count || s[next].properties.isWhitespace || closing.contains(s[next])
    }
    return !isWordScalar(c) && !forbiddenAfter.contains(c)
  }
}
