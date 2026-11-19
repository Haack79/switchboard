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

  /// Where the URL whose scheme ends at `schemeEnd` ends, read as cmark-gfm
  /// ends an autolink: at ASCII whitespace, `<`, or `limit`, the end of the
  /// run, and then without trailing `?!.,:*_~'"`, without a trailing `)`
  /// while the URL holds more `)` than `(`, and without a trailing `;` or
  /// `&entity;`. The trim never reaches back past `schemeEnd`. `cut` is true
  /// when the URL runs on into the next run, so that its text in this run is
  /// not all of it.
  static func autolinkEnd(after schemeEnd: Int, before limit: Int, _ s: [Unicode.Scalar]) -> (end: Int, cut: Bool) {
    var end = schemeEnd
    var opening = 0
    var closing = 0
    while end < limit, !isASCIISpace(s[end]), s[end] != "<" {
      if s[end] == "(" { opening += 1 } else if s[end] == ")" { closing += 1 }
      end += 1
    }
    let cut = end == limit && limit < s.count && !isASCIISpace(s[limit]) && s[limit] != "<"
    trimming: while end > schemeEnd {
      switch s[end - 1] {
      case ")":
        guard closing > opening else { break trimming }
        closing -= 1
        end -= 1
      case "?", "!", ".", ",", ":", "*", "_", "~", "'", "\"":
        end -= 1
      case ";":
        var entity = end - 2
        while entity > schemeEnd, s[entity].isASCII, s[entity].properties.isAlphabetic { entity -= 1 }
        end = entity < end - 2 && s[entity] == "&" ? entity : end - 1
      default:
        break trimming
      }
    }
    return (end, cut)
  }

  /// The index after `word` when `s` spells it at `i`, ignoring ASCII case.
  static func spells(_ word: String, at i: Int, before limit: Int, _ s: [Unicode.Scalar]) -> Int? {
    var j = i
    for c in word.unicodeScalars {
      guard j < limit, s[j] == c || (s[j].value ^ 0x20 == c.value && s[j].properties.isAlphabetic) else {
        return nil
      }
      j += 1
    }
    return j
  }

  private static func isASCIISpace(_ c: Unicode.Scalar) -> Bool {
    c == " " || c == "\t" || c == "\n" || c == "\u{0B}" || c == "\u{0C}" || c == "\r"
  }
}
