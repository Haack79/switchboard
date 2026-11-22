import Foundation
import SwitchboardCore
import Testing

// The Stage 2 API that these tests call. Each guessed name appears once, here.

private func codex(_ folder: String) -> CodexAccount { CodexAccount(folder: folder) }

private func discovered(_ home: String) -> [Account] { Account.discover(home: home) }

private func resolve(_ ref: String, among known: [Account]) throws -> Account {
  try Account.resolve(ref, among: known)
}

private func agent(_ account: Account) -> Agent { account.agent }

private func codexOf(_ account: Account) -> CodexAccount? { account.codex }

/// A home folder in the temporary folder, so discovery never reads the
/// user's ~/.claude* or ~/.codex*.
private struct FakeHome {
  let path: String

  init() throws { path = try tempFolder() }

  /// Makes the folder `name` in the home, with an empty file for each of
  /// `files`, and returns its path.
  @discardableResult
  func folder(_ name: String, holding files: [String] = []) throws -> String {
    let folder = "\(path)/\(name)"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    for file in files { FileManager.default.createFile(atPath: "\(folder)/\(file)", contents: Data("{}".utf8)) }
    return folder
  }

  func remove() { try? FileManager.default.removeItem(atPath: path) }

  func account(at folder: String) -> Account? { discovered(path).first { $0.folder == folder } }
}

@Suite struct CodexAccountNames {
  @Test(arguments: [
    ("~/.codex", "codex"), ("~/.codex-work", "codex-work"), ("/tmp/home/.codex", "codex"),
    ("/tmp/home/.codex-personal/", "codex-personal"),
  ])
  func aCodexFolderIsNamedWithItsAgent(_ folder: String, _ name: String) {
    #expect(codex(folder).name == name)
  }

  @Test func theNamesOfAClaudeAndACodexFolderWithTheSameSuffixDiffer() {
    #expect(ClaudeAccount(folder: "~/.claude-work").name != codex("~/.codex-work").name)
  }

  @Test func twoFormsOfOneFolderAreOneCodexAccount() {
    let accounts: Set = [codex("~/.codex-work/"), codex("~/.codex-work"), codex("~/x/../.codex-work")]

    #expect(accounts.count == 1)
    #expect(accounts.first?.folder == "\(NSHomeDirectory())/.codex-work")
  }

  @Test(arguments: ["~/.codex", "~/.codex-work", "/tmp/home/.codex-x"])
  func applySetsCodexHomeToTheFolder(_ folder: String) {
    var env = ["PATH": "/usr/bin"]

    codex(folder).apply(to: &env)

    #expect(env["CODEX_HOME"] == codex(folder).folder)
    #expect(env["PATH"] == "/usr/bin")
  }

  @Test(arguments: ["/tmp/home/.codex-work", "/tmp/my home/.codex-it's"])
  func theLoginCommandSetsCodexHomeAndRunsCodexLogin(_ folder: String) {
    #expect(codex(folder).loginCommand == "CODEX_HOME=\(shellQuote(folder)) codex login")
  }
}

@Suite struct CodexAccountEnum {
  @Test func aCodexAccountGivesItsFolderNameAndAgentAndNoClaudeAccount() {
    let account = Account.codex(codex("~/.codex-work"))

    #expect(account.folder == codex("~/.codex-work").folder)
    #expect(account.name == "codex-work")
    #expect(agent(account) == .codex)
    #expect(codexOf(account) == codex("~/.codex-work"))
    #expect(account.claude == nil)
  }

  @Test func aClaudeAccountRunsClaudeAndHasNoCodexAccount() {
    let account = Account.claude(ClaudeAccount(folder: "~/.claude-work"))

    #expect(agent(account) == .claude)
    #expect(codexOf(account) == nil)
  }

  /// `--json` output and stored rows write the agent by these names.
  @Test func theAgentsAreNamedClaudeAndCodex() {
    #expect(Agent.claude.rawValue == "claude")
    #expect(Agent.codex.rawValue == "codex")
  }
}

/// Discovery by name (H1 a): ~/.codex and each ~/.codex-* folder is a Codex
/// account. A Codex folder needs no file, because a keyring login leaves none.
@Suite struct CodexAccountDiscovery {
  @Test func findsTheDefaultCodexFolderAsTheCodexAccount() throws {
    let home = try FakeHome()
    defer { home.remove() }
    let folder = try home.folder(".codex")

    let account = try #require(home.account(at: folder))

    #expect(agent(account) == .codex)
    #expect(account.name == "codex")
  }

  @Test(arguments: [[], ["config.toml"], ["auth.json"], ["config.toml", "auth.json"]])
  func findsACodexDashFolderWithOrWithoutItsFiles(_ files: [String]) throws {
    let home = try FakeHome()
    defer { home.remove() }
    let folder = try home.folder(".codex-x", holding: files)

    let account = try #require(home.account(at: folder), "\(files)")

    #expect(agent(account) == .codex)
    #expect(account.name == "codex-x")
  }

  /// The folder matches both kinds, so discovery refuses it instead of guessing.
  @Test(arguments: [[".claude.json"], [".claude.json", "config.toml", "auth.json"]])
  func refusesACodexFolderThatHoldsAClaudeLogin(_ files: [String]) throws {
    let home = try FakeHome()
    defer { home.remove() }
    let folder = try home.folder(".codex-x", holding: files)

    #expect(home.account(at: folder) == nil)
  }

  @Test func refusesTheDefaultCodexFolderWhenItHoldsAClaudeLogin() throws {
    let home = try FakeHome()
    defer { home.remove() }
    let folder = try home.folder(".codex", holding: [".claude.json"])

    #expect(home.account(at: folder) == nil)
  }

  @Test(arguments: [".codexfoo", "codex", "codex-x", ".Codex-x"])
  func aFolderWhoseNameIsNotCodexOrCodexDashIsNotACodexAccount(_ name: String) throws {
    let home = try FakeHome()
    defer { home.remove() }
    let folder = try home.folder(name, holding: ["config.toml", "auth.json"])

    #expect(home.account(at: folder) == nil)
  }

  @Test func aFileNamedLikeACodexFolderIsNotAnAccount() throws {
    let home = try FakeHome()
    defer { home.remove() }
    FileManager.default.createFile(atPath: "\(home.path)/.codex-notes", contents: Data("x".utf8))

    #expect(home.account(at: "\(home.path)/.codex-notes") == nil)
  }

  @Test func aClaudeFolderWithAClaudeLoginStaysAClaudeAccount() throws {
    let home = try FakeHome()
    defer { home.remove() }
    let folder = try home.folder(".claude-a", holding: [".claude.json"])

    let account = try #require(home.account(at: folder))

    #expect(agent(account) == .claude)
    #expect(account.name == "a")
  }

  /// The Claude accounts that discovery finds, in their order, don't change
  /// when Codex folders sit beside them.
  @Test func theClaudeAccountsAreTheOnesClaudeDiscoveryFinds() throws {
    let home = try FakeHome()
    defer { home.remove() }
    try home.folder(".claude-a", holding: [".claude.json"])
    try home.folder(".claude-b")
    try home.folder(".claude-c", holding: [".claude.json"])
    try home.folder(".codex")
    try home.folder(".codex-work", holding: ["auth.json"])
    try home.folder(".codex-both", holding: [".claude.json"])

    let accounts = discovered(home.path)

    #expect(accounts.compactMap(\.claude) == ClaudeAccount.discover(home: home.path))
    #expect(Set(accounts.compactMap(codexOf).map(\.name)) == ["codex", "codex-work"])
  }

  @Test func eachFolderIsListedOnceWithOneAgent() throws {
    let home = try FakeHome()
    defer { home.remove() }
    try home.folder(".claude-a", holding: [".claude.json"])
    try home.folder(".codex")
    try home.folder(".codex-work")

    let folders = discovered(home.path).map(\.folder)

    #expect(folders.count == Set(folders).count)
  }
}

/// `Account.resolve` takes a name or a folder for `--account`, `sb account
/// use`, and the group account.
@Suite struct CodexAccountResolve {
  @Test func aCodexNameResolvesToTheCodexAccount() throws {
    let home = try FakeHome()
    defer { home.remove() }
    let folder = try home.folder(".codex-work")
    try home.folder(".claude-a", holding: [".claude.json"])

    let account = try resolve("codex-work", among: discovered(home.path))

    #expect(account == .codex(codex(folder)))
  }

  @Test func aClaudeNameStillResolvesToTheClaudeAccount() throws {
    let home = try FakeHome()
    defer { home.remove() }
    let folder = try home.folder(".claude-a", holding: [".claude.json"])
    try home.folder(".codex-a")

    let account = try resolve("a", among: discovered(home.path))

    #expect(account == .claude(ClaudeAccount(folder: folder)))
  }

  /// H3 keeps the agent in a Codex name, so only a Claude folder named
  /// `.claude-codex…` can collide with one. The name then resolves to neither.
  @Test(arguments: [(".claude-codex-work", ".codex-work", "codex-work"), (".claude-codex", ".codex", "codex")])
  func refusesANameThatBothAClaudeAndACodexAccountHave(_ claude: String, _ codexName: String, _ name: String) throws {
    let home = try FakeHome()
    defer { home.remove() }
    try home.folder(claude, holding: [".claude.json"])
    try home.folder(codexName)
    let known = discovered(home.path)
    #expect(known.filter { $0.name == name }.count == 2)

    let error = #expect(throws: (any Error).self) { try resolve(name, among: known) }

    #expect(error.map { "\($0)" }?.contains(name) == true)
  }

  @Test(arguments: [(".claude-codex-work", ".codex-work"), (".claude-codex", ".codex")])
  func eachFolderOfAnAmbiguousNameStillResolvesToItsOwnKind(_ claude: String, _ codexName: String) throws {
    let home = try FakeHome()
    defer { home.remove() }
    let claudeFolder = try home.folder(claude, holding: [".claude.json"])
    let codexFolder = try home.folder(codexName)
    let known = discovered(home.path)

    for form in [claudeFolder, claudeFolder + "/"] {
      #expect(try resolve(form, among: known) == .claude(ClaudeAccount(folder: claudeFolder)), "\(form)")
    }
    for form in [codexFolder, codexFolder + "/"] {
      #expect(try resolve(form, among: known) == .codex(codex(codexFolder)), "\(form)")
    }
  }

  /// A path that `--account` names directly is classified like a discovered folder.
  @Test(arguments: [[], ["config.toml", "auth.json"]])
  func aCodexDashFolderGivenByPathIsACodexAccount(_ files: [String]) throws {
    let home = try FakeHome()
    defer { home.remove() }
    let folder = try home.folder(".codex-elsewhere", holding: files)

    let account = try resolve(folder, among: [])

    #expect(account == .codex(codex(folder)))
  }

  @Test func refusesACodexFolderGivenByPathThatHoldsAClaudeLogin() throws {
    let home = try FakeHome()
    defer { home.remove() }
    let folder = try home.folder(".codex-x", holding: [".claude.json"])

    #expect(throws: (any Error).self) { try resolve(folder, among: discovered(home.path)) }
    #expect(throws: (any Error).self) { try resolve(folder, among: []) }
  }

  /// The Claude branch keeps requiring .claude.json. Codex files don't make
  /// a folder that isn't named like a Codex folder a Codex account.
  @Test func refusesAFolderThatHoldsOnlyCodexFilesButIsNotNamedLikeACodexFolder() throws {
    let home = try FakeHome()
    defer { home.remove() }
    let folder = try home.folder("elsewhere", holding: ["config.toml", "auth.json"])

    #expect(throws: (any Error).self) { try resolve(folder, among: []) }
  }

  @Test func aClaudeFolderGivenByPathStillNeedsAClaudeLogin() throws {
    let home = try FakeHome()
    defer { home.remove() }
    let empty = try home.folder(".claude-empty")
    let signed = try home.folder(".claude-signed", holding: [".claude.json"])

    #expect(throws: (any Error).self) { try resolve(empty, among: []) }
    #expect(try resolve(signed, among: []) == .claude(ClaudeAccount(folder: signed)))
  }

  /// A `codexHomes` entry need not be named like a Codex folder. Its path
  /// resolves to the known account.
  @Test func aKnownCodexAccountAtAnyPathResolvesByItsFolder() throws {
    let home = try FakeHome()
    defer { home.remove() }
    let folder = try home.folder("codex-homes/work")
    let known: [Account] = [.codex(codex(folder))]

    #expect(try resolve(folder, among: known) == .codex(codex(folder)))
    #expect(try resolve(folder + "/", among: known) == .codex(codex(folder)))
  }

  @Test func anUnknownNameIsRefused() throws {
    let home = try FakeHome()
    defer { home.remove() }
    try home.folder(".codex-work")

    #expect(throws: (any Error).self) { try resolve("nobody", among: discovered(home.path)) }
  }
}

/// H1: `codexHomes` in config.json replaces discovery when set, like
/// `claudeConfigDirs`. `codex` names the program that sbd runs for
/// `codex login status`.
@Suite struct CodexAccountConfig {
  @Test(
    arguments: [
      (#"{}"#, nil), (#"{"codexHomes": null}"#, nil), (#"{"codexHomes": []}"#, []),
      (#"{"codexHomes": ["~/.codex", "/work/codex-homes/x"]}"#, ["~/.codex", "/work/codex-homes/x"]),
    ] as [(String, [String]?)])
  func codexHomesIsNilOnlyWhenMissing(_ text: String, _ homes: [String]?) throws {
    #expect(try JSONCoding.decode(Config.self, from: text).codexHomes == homes)
  }

  @Test func theCodexProgramDefaultsToCodex() throws {
    #expect(try JSONCoding.decode(Config.self, from: "{}").codex == "codex")
    #expect(try JSONCoding.decode(Config.self, from: #"{"codex": "/opt/stub"}"#).codex == "/opt/stub")
  }
}

/// `Account.listed` with the `claudeConfigDirs` and `codexHomes` overrides.
@Suite struct CodexAccountListed {
  /// A Mac's file system usually ignores case, so ~/.Codex-x can be the Codex folder ~/.codex-x.
  @Test(arguments: [".codex-x", ".Codex-x", ".CODEX"])
  func aClaudeConfigDirsEntryNamedLikeACodexFolderInAnyCaseIsNoClaudeAccount(_ name: String) throws {
    let home = try FakeHome()
    defer { home.remove() }
    let folder = try home.folder(name, holding: [".claude.json"])

    let accounts = Account.listed(claudeConfigDirs: [folder], codexHomes: [], home: home.path)

    #expect(accounts.compactMap(\.claude).isEmpty, "\(accounts)")
  }

  /// A folder that both lists name is never a Claude account.
  @Test func aFolderInBothListsIsOnlyACodexAccount() throws {
    let home = try FakeHome()
    defer { home.remove() }
    let folder = try home.folder("shared")

    let accounts = Account.listed(claudeConfigDirs: [folder], codexHomes: [folder], home: home.path)

    #expect(accounts == [.codex(codex(folder))])
  }
}

/// H1: a folder that matches both kinds is refused with a message, which sbd logs at start.
@Suite struct CodexAccountRefusals {
  @Test func eachFolderThatMatchesBothKindsHasAReason() throws {
    let home = try FakeHome()
    defer { home.remove() }
    let both = try home.folder(".codex-both", holding: [".claude.json"])
    try home.folder(".codex-ok")
    try home.folder(".claude-a", holding: [".claude.json"])

    let reasons = Account.refusals(claudeConfigDirs: nil, codexHomes: nil, home: home.path)

    #expect(reasons.count == 1, "\(reasons)")
    #expect(reasons.first?.contains(both) == true, "\(reasons)")
  }

  @Test func aClaudeConfigDirsEntryThatCodexHomesListsHasAReason() throws {
    let home = try FakeHome()
    defer { home.remove() }
    let shared = try home.folder("shared")

    let reasons = Account.refusals(claudeConfigDirs: [shared], codexHomes: [shared], home: home.path)

    #expect(reasons.map { $0.contains("codexHomes") } == [true], "\(reasons)")
  }
}
