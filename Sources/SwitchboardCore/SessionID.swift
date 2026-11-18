/// The shape of a session id: `swb_` and then `ShortId.length` characters from `ShortId.alphabet`. Sessions made
/// before `swb_` ids have `s` and then `ShortId.length` characters, and both forms stay valid.
public enum SessionID {
  /// The prefix of each new session's id.
  public static let prefix = "swb_"

  /// Whether `s` has the shape of a session id.
  public static func isValid(_ s: String) -> Bool {
    let scalars = Array(s.unicodeScalars)
    return length(at: 0, in: scalars, before: scalars.count) == scalars.count
  }

  /// The length of the id that starts at `i` and ends at or before `limit`, or nil when no id starts there. `limit`
  /// is at most `s.count`.
  public static func length(at i: Int, in s: [Unicode.Scalar], before limit: Int) -> Int? {
    guard i < limit, s[i] == "s" else { return nil }
    let head = s[i..<limit].starts(with: prefixScalars) ? prefixScalars.count : 1
    let end = i + head + ShortId.length
    return end <= limit && s[i + head..<end].allSatisfy(inAlphabet) ? end - i : nil
  }

  private static let prefixScalars = Array(prefix.unicodeScalars)

  /// A table indexed by ASCII code, so that the matcher's test for each scalar does not hash.
  private static let alphabet: [Bool] = {
    var table = [Bool](repeating: false, count: 128)
    for c in ShortId.alphabet.unicodeScalars { table[Int(c.value)] = true }
    return table
  }()

  private static func inAlphabet(_ c: Unicode.Scalar) -> Bool { c.value < 128 && alphabet[Int(c.value)] }
}
