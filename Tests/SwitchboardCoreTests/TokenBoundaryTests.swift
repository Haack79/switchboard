import Testing

@testable import SwitchboardCore

struct TokenBoundaryTests {
  /// The three scalars before the scheme's end and every scalar after it are ones that the trim removes, so only the
  /// floor at the scheme's end stops it. `&ab;` would otherwise trim as an entity that starts before the scheme's end.
  @Test(arguments: ["....", "...)", "...;", "...?!.,:*_~'\"", "&ab;"])
  func theAutolinkTrimStopsAtTheSchemesEnd(_ text: String) {
    let s = Array(text.unicodeScalars)

    let (end, cut) = TokenBoundary.autolinkEnd(after: 3, before: s.count, s)

    #expect(end == 3)
    #expect(!cut)
  }
}
