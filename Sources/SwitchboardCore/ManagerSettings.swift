/// config.json's `manager` section, for sessions of kind `manager`.
public struct ManagerSettings: Codable, Equatable, Sendable {
  /// The auto-compact window, in tokens, that sbd sets as `CLAUDE_CODE_AUTO_COMPACT_WINDOW` when it starts or
  /// resumes a Manager conversation. Claude Code compacts about 33k tokens below the window, so 183000 compacts
  /// near 150k. Claude Code reads a value under 100000 as 100000. With 0, sbd sets nothing and claude uses its own window.
  public var autoCompactWindow = 183_000

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    autoCompactWindow =
      try c.decodeIfPresent(Int.self, forKey: .autoCompactWindow) ?? ManagerSettings().autoCompactWindow
  }

  /// Sets the window in the environment of a Manager conversation's claude. It replaces a value that
  /// config.json's `env` set. A window of 0 or less leaves the environment as it is.
  public func apply(to env: inout [String: String]) {
    guard autoCompactWindow > 0 else { return }
    env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = String(autoCompactWindow)
  }
}
