import Foundation
import Testing

@testable import SwitchboardCore

/// `removalDelaySeconds` in config.json. A bad value keeps the default 5 and leaves the other keys alone.
@Suite struct RemovalDelayConfigTests {
  func config(_ delay: String) throws -> Config {
    try JSONCoding.decode(Config.self, from: #"{"liveCap": 7, "removalDelaySeconds": \#(delay)}"#)
  }

  @Test(arguments: [("0", 0), ("600", 600), ("86400", 86_400), ("null", 5)])
  func aWholeNumberInRangeSetsTheDelay(_ text: String, _ expected: Int) throws {
    #expect(try config(text).removalDelaySeconds == expected)
  }

  @Test(arguments: ["2.5", "-1", "86401", "\"5\"", "true"])
  func aBadValueKeepsTheDefaultAndTheRestOfTheConfig(_ text: String) throws {
    let config = try config(text)

    #expect(config.removalDelaySeconds == 5)
    #expect(config.liveCap == 7)
  }
}
