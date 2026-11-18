import Testing

@testable import SwitchboardCore

/// A session id is `s` and 5 characters from `ShortId.alphabet` (6 scalars), or `swb_` and 5 characters from it
/// (9 scalars). Nothing else is one.
@Suite struct SessionIDTests {
  private static let oldForm = ["seb4ec", "sgcctv", "s23456", "szzzzz", "saaaaa", "swbeb4", "sw2345"]
  private static let newForm = ["swb_eb4ec", "swb_23456", "swb_zzzzz", "swb_aaaaa", "swb_s2abc", "swb_swb22"]

  /// Each string misses both shapes in one way.
  private static let notIds = [
    // Old form: length, case, letters outside the alphabet, and non-ASCII.
    "", "s", "seb4e", "seb4ecx", "Seb4ec", "SEB4EC", "seb4e1", "seb4eo", "seb4el", "seb4e0", "seb4é", "seb4eé",
    "seb4e\u{0663}", "xeb4ec", "geb4ec", "seb4ec ", " seb4ec", "seb4ec\n", "seb4e.", "seb4e/", "seb4e_",
    // New form: length, case, the prefix, and letters outside the alphabet.
    "swb_", "swb_eb4e", "swb_eb4ec1", "swb_eb4eC", "swb_eb4e1", "swb_eb4eo", "SWB_eb4ec", "Swb_eb4ec", "sWb_eb4ec",
    "swb-eb4ec", "swb__eb4e", "swb__eb4ec", "swbeb4ec", "sw_eb4ec", "wb_eb4ec", "_eb4ec", "swb_EB4EC",
    "swb_eb4é", "swb_eb4eé", "swb_eb4e\u{0663}", "swb_eb4e🙂", "swb_eb4e\u{0}", "ѕwb_eb4ec",
    // Paths, dot segments, and whitespace around the id.
    "swb_eb4ec/..", "swb_/../x", "swb_..", "swb_eb4e.", "swb_eb4ec/", "./swb_eb4ec", "swb_eb4ec ", " swb_eb4ec",
    "swb_eb4ec\n", "swb_eb4ec-claude", "seb4ec-claude",
    // Two ids in a row.
    "seb4ecseb4ec", "swb_eb4ecswb_eb4ec", "swb_eb4ecseb4ec",
  ]

  private func scalars(_ s: String) -> [Unicode.Scalar] { Array(s.unicodeScalars) }

  @Test(arguments: oldForm + newForm)
  func anIdOfEitherFormIsValid(_ id: String) {
    #expect(SessionID.isValid(id))
  }

  @Test(arguments: notIds)
  func aStringThatMissesBothShapesIsNotValid(_ s: String) {
    #expect(!SessionID.isValid(s))
  }

  /// `isValid` and the matcher's `length(at:)` must accept the same ids, or an id would link in text and fail to
  /// parse as a link target, or the reverse.
  @Test(arguments: oldForm + newForm + notIds)
  func isValidAgreesWithALengthThatCoversTheWholeString(_ s: String) {
    let count = s.unicodeScalars.count

    #expect(SessionID.isValid(s) == (SessionID.length(at: 0, in: scalars(s), before: count) == count))
  }

  @Test(
    arguments: [
      ("see seb4ec now", 4, 6),
      ("see swb_eb4ec now", 4, 9),
      ("(swb_eb4ec)", 1, 9),
      ("é swb_eb4ec", 2, 9),
      // The matcher's boundary check refuses this old-form shape, because `_` comes before it.
      ("swb_s2abcd", 4, 6),
    ] as [(String, Int, Int)])
  func lengthFindsAnIdThatStartsInsideText(_ text: String, _ start: Int, _ length: Int) {
    let s = scalars(text)

    #expect(SessionID.length(at: start, in: s, before: s.count) == length)
  }

  /// Whether the id is a whole token is the matcher's question, not `length(at:)`'s.
  @Test(
    arguments: [("seb4ecx", 6), ("seb4ec_x", 6), ("swb_eb4ecx", 9), ("swb_eb4ec_x", 9), ("swb_eb4ec2", 9)]
      as [(String, Int)])
  func lengthIgnoresWhatFollowsTheId(_ text: String, _ length: Int) {
    let s = scalars(text)

    #expect(SessionID.length(at: 0, in: s, before: s.count) == length)
  }

  /// The limit is the end of the run that holds the id. A new id that would end past it must not match. It must not
  /// shrink to an old id either, because the old form needs an alphabet character where the new form puts `_`.
  @Test(arguments: 4...8)
  func aNewIdThatEndsPastTheLimitHasNoLength(_ limit: Int) {
    #expect(SessionID.length(at: 0, in: scalars("swb_eb4ec"), before: limit) == nil)
  }

  @Test(arguments: 1...5)
  func anOldIdThatEndsPastTheLimitHasNoLength(_ limit: Int) {
    #expect(SessionID.length(at: 0, in: scalars("seb4ec"), before: limit) == nil)
  }

  @Test func aNewIdThatEndsExactlyAtTheLimitHasItsLength() {
    #expect(SessionID.length(at: 0, in: scalars("swb_eb4ecswb"), before: 9) == 9)
  }

  @Test func anIdThatStartsTooCloseToTheLimitHasNoLength() {
    let s = scalars("xx seb4ec")

    #expect(SessionID.length(at: 3, in: s, before: 8) == nil)
  }
}
