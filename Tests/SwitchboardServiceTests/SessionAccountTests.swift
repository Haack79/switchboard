import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// The key that events, logs, and quota lookups record for a session's account.
@Suite struct SessionAccountKey {
  @Test func aLocalAccountIsKeyedByItsNormalizedFolder() {
    #expect(SessionAccount.local(ClaudeAccount(folder: "~/.claude-work/")).key == "\(NSHomeDirectory())/.claude-work")
  }

  @Test func theDefaultAccountIsKeyedByTheDefaultFolder() {
    #expect(SessionAccount.local(ClaudeAccount(folder: "~/.claude")).key == ClaudeAccount.defaultFolder)
  }

  @Test func aHostIsKeyedByItsLoginLabel() {
    #expect(SessionAccount.host("mini").key == "mini:~/.claude")
  }

  @Test func aHostLabelNeverEqualsALocalAccount() {
    #expect(SessionAccount.host("mini") != .local(ClaudeAccount(folder: "mini:~/.claude")))
  }
}
