import SwitchboardCore
import Testing

@Suite struct AccountEnumTests {
  @Test(arguments: ["~/.claude/", "~/.claude-personal/", "/work/accounts/acme"])
  func aClaudeAccountGivesItsFolderNameAndClaudeAccount(_ folder: String) {
    let claude = ClaudeAccount(folder: folder)

    let account = Account.claude(claude)

    #expect(account.folder == claude.folder)
    #expect(account.name == claude.name)
    #expect(account.claude == claude)
  }

  @Test func twoFormsOfOneFolderAreOneAccount() {
    let accounts: Set = [
      Account.claude(ClaudeAccount(folder: "~/.claude/")), .claude(ClaudeAccount(folder: "~/.claude")),
    ]

    #expect(accounts.count == 1)
  }
}
