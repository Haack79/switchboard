import Foundation

/// The CLI that an account's sessions run. `--json` output writes it by its raw value.
public enum Agent: String, Codable, Hashable, Sendable, CaseIterable {
  case claude, codex
}

/// An account that sessions run under. Each case is one agent's config
/// folder.
public enum Account: Hashable, Sendable {
  case claude(ClaudeAccount)
  case codex(CodexAccount)

  /// The normalized config folder.
  public var folder: String {
    switch self {
    case .claude(let account): account.folder
    case .codex(let account): account.folder
    }
  }

  /// The short name that `--account` and `sb account use` take.
  public var name: String {
    switch self {
    case .claude(let account): account.name
    case .codex(let account): account.name
    }
  }

  public var agent: Agent {
    switch self {
    case .claude: .claude
    case .codex: .codex
    }
  }

  /// The Claude account, or nil when the account runs another agent.
  public var claude: ClaudeAccount? {
    switch self {
    case .claude(let account): account
    case .codex: nil
    }
  }

  /// The Codex account, or nil when the account runs another agent.
  public var codex: CodexAccount? {
    switch self {
    case .claude: nil
    case .codex(let account): account
    }
  }

  /// The short name of a stored folder, judged by the folder's name alone.
  /// It is the name that `name` gives once the folder is listed, except for
  /// a `codexHomes` entry named like a Claude folder, which no list holds.
  public static func name(ofFolder folder: String) -> String {
    CodexAccount.isNamedLikeCodex(folder) ? CodexAccount(folder: folder).name : ClaudeAccount(folder: folder).name
  }

  /// The accounts that sbd lists. `claudeConfigDirs` and `codexHomes`
  /// replace discovery of their kind when set. A folder named like a Codex
  /// folder, or one that `codexHomes` lists, is never a Claude account. A
  /// Codex folder that holds a Claude login or is named like a Claude folder
  /// is neither kind.
  public static func listed(
    claudeConfigDirs: [String]?, codexHomes: [String]?, home: String = NSHomeDirectory()
  ) -> [Account] {
    let found = candidates(claudeConfigDirs: claudeConfigDirs, codexHomes: codexHomes, home: home)
    let claude = found.claude.filter { claudeClash($0, codexHomes: codexHomes) == nil }
    var seen = Set<String>()
    return (claude.map(Account.claude) + found.codex.filter { $0.clash == nil }.map(Account.codex))
      .filter { seen.insert($0.folder).inserted }
  }

  /// Why `listed` leaves out each folder that a list names or discovery finds, for sbd's log.
  public static func refusals(
    claudeConfigDirs: [String]?, codexHomes: [String]?, home: String = NSHomeDirectory()
  ) -> [String] {
    let found = candidates(claudeConfigDirs: claudeConfigDirs, codexHomes: codexHomes, home: home)
    return found.claude.compactMap { claudeClash($0, codexHomes: codexHomes) } + found.codex.compactMap(\.clash)
  }

  private static func candidates(
    claudeConfigDirs: [String]?, codexHomes: [String]?, home: String
  ) -> (claude: [ClaudeAccount], codex: [CodexAccount]) {
    (
      claudeConfigDirs?.map(ClaudeAccount.init(folder:)) ?? ClaudeAccount.discover(home: home),
      codexHomes?.map(CodexAccount.init(folder:)) ?? CodexAccount.discover(home: home)
    )
  }

  /// Why a Claude folder is no Claude account: it is named like a Codex folder, in any case, or `codexHomes`
  /// lists it.
  private static func claudeClash(_ account: ClaudeAccount, codexHomes: [String]?) -> String? {
    if CodexAccount.isNamedLikeCodex(account.folder, ignoringCase: true) {
      return "\(account.folder) is named like a Codex folder, so it is no Claude account"
    }
    if (codexHomes ?? []).contains(where: { ClaudeAccount.normalize($0) == account.folder }) {
      return "codexHomes lists \(account.folder), so it is no Claude account"
    }
    return nil
  }

  /// The Claude accounts and then the Codex accounts in the home folder.
  public static func discover(home: String = NSHomeDirectory()) -> [Account] {
    listed(claudeConfigDirs: nil, codexHomes: nil, home: home)
  }

  /// The account that `ref` names: a short name, or a folder. A name that
  /// two known accounts share is refused, so that it never picks one
  /// silently. A folder that no known account has is a Codex account when it
  /// is named like one, and a Claude account when it holds a Claude login.
  public static func resolve(_ ref: String, among known: [Account]) throws -> Account {
    let named = known.filter { $0.name == ref }
    if named.count > 1 {
      let folders = named.map(\.folder).joined(separator: ", ")
      throw APIError("\(ref) names more than one account (\(folders)). Name the account by its folder")
    }
    if let match = named.first { return match }
    let folder = ClaudeAccount.normalize(ref)
    if let match = known.first(where: { $0.folder == folder }) { return match }
    if CodexAccount.isNamedLikeCodex(folder) {
      let account = CodexAccount(folder: folder)
      if let clash = account.clash { throw APIError(clash) }
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
        throw APIError("\(ref) is no Codex account (no folder \(folder))")
      }
      return .codex(account)
    }
    let account = ClaudeAccount(folder: folder)
    guard account.holdsAccount else {
      let names = known.map(\.name).joined(separator: ", ")
      throw APIError(
        "\(ref) is no Claude account (no .claude.json in \(account.folder)). Known accounts: \(names)")
    }
    return .claude(account)
  }
}
