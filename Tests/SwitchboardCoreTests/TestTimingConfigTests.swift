import Foundation
import Testing

@testable import SwitchboardCore

/// The config.json keys that let a test shorten sbd's waits. Without them, sbd keeps the production waits.
@Suite struct TestTimingConfigTests {
  @Test func aConfigWithoutTheKeysKeepsTheProductionWaits() throws {
    let config = try JSONCoding.decode(Config.self, from: "{}")

    #expect(config.pasteSettleSeconds == 1.5)
    #expect(config.stopWaitSeconds == 5)
    #expect(config.reviewTimeoutSeconds == 60)
  }

  @Test func theKeysSetTheWaits() throws {
    let config = try JSONCoding.decode(
      Config.self, from: #"{"pasteSettleSeconds": 0.2, "stopWaitSeconds": 2, "reviewTimeoutSeconds": 5}"#)

    #expect(config.pasteSettleSeconds == 0.2)
    #expect(config.stopWaitSeconds == 2)
    #expect(config.reviewTimeoutSeconds == 5)
  }
}
