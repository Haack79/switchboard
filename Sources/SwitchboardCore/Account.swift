import Foundation

/// An account that sessions run under. Each case is one agent's config
/// folder.
public enum Account: Hashable, Sendable {
  case claude(ClaudeAccount)

  /// The normalized config folder.
  public var folder: String {
    switch self {
    case .claude(let account): account.folder
    }
  }

  /// The short name that `--account` and `sb account use` take.
  public var name: String {
    switch self {
    case .claude(let account): account.name
    }
  }

  /// The Claude account, or nil when the account runs another agent.
  public var claude: ClaudeAccount? {
    switch self {
    case .claude(let account): account
    }
  }
}
