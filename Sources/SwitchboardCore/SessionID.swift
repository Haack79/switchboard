/// The shape of a session id: `swb_` and then `ShortId.length` characters from `ShortId.alphabet`. Sessions made
/// before `swb_` ids have `s` and then `ShortId.length` characters, and both forms stay valid.
public enum SessionID {
  /// The prefix of each new session's id.
  public static let prefix = "swb_"

  /// The length of the older, shorter form.
  public static let minLength = 1 + ShortId.length

  /// Whether `s` has the shape of a session id.
  public static func isValid(_ s: String) -> Bool {
    let scalars = Array(s.unicodeScalars)
    return length(at: 0, in: scalars, before: scalars.count) == scalars.count
  }

  /// The length of the id that starts at `i` and ends at or before `limit`, or nil when no id starts there.
  public static func length(at i: Int, in s: [Unicode.Scalar], before limit: Int) -> Int? {
    let limit = min(limit, s.count)
    guard i >= 0, i < limit, s[i] == "s" else { return nil }
    if fits(after: prefixScalars.count, at: i, in: s, before: limit),
      s[i..<i + prefixScalars.count].elementsEqual(prefixScalars)
    {
      return prefixScalars.count + ShortId.length
    }
    return fits(after: 1, at: i, in: s, before: limit) ? minLength : nil
  }

  private static let prefixScalars = Array(prefix.unicodeScalars)

  /// Whether `ShortId.length` alphabet characters follow the first `head` scalars of `s` at `i`, before `limit`.
  private static func fits(after head: Int, at i: Int, in s: [Unicode.Scalar], before limit: Int) -> Bool {
    let end = i + head + ShortId.length
    return end <= limit && s[i + head..<end].allSatisfy(inAlphabet)
  }

  /// A table indexed by ASCII code, so that the matcher's test for each scalar does not hash.
  private static let alphabet: [Bool] = {
    var table = [Bool](repeating: false, count: 128)
    for c in ShortId.alphabet.unicodeScalars { table[Int(c.value)] = true }
    return table
  }()

  private static func inAlphabet(_ c: Unicode.Scalar) -> Bool { c.value < 128 && alphabet[Int(c.value)] }
}
