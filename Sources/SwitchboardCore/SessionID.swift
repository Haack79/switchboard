/// The shape of a session id: `s` and then `ShortId.length` characters from `ShortId.alphabet`.
public enum SessionID {
  /// The length of the shortest id.
  public static let minLength = 1 + ShortId.length

  /// Whether `s` has the shape of a session id.
  public static func isValid(_ s: String) -> Bool {
    let scalars = Array(s.unicodeScalars)
    return length(at: 0, in: scalars, before: scalars.count) == scalars.count
  }

  /// The length of the id that starts at `i` and ends at or before `limit`, or nil when no id starts there.
  public static func length(at i: Int, in s: [Unicode.Scalar], before limit: Int) -> Int? {
    let end = i + minLength
    guard i >= 0, end <= limit, end <= s.count, s[i] == "s", s[i + 1..<end].allSatisfy(inAlphabet) else { return nil }
    return minLength
  }

  /// A table indexed by ASCII code, so that the matcher's test for each scalar does not hash.
  private static let alphabet: [Bool] = {
    var table = [Bool](repeating: false, count: 128)
    for c in ShortId.alphabet.unicodeScalars { table[Int(c.value)] = true }
    return table
  }()

  private static func inAlphabet(_ c: Unicode.Scalar) -> Bool { c.value < 128 && alphabet[Int(c.value)] }
}
