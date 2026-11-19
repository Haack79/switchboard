/// config.json's `manager` section, for sessions of kind `manager`.
public struct ManagerSettings: Codable, Equatable, Sendable {
  /// The model that a Manager conversation runs, unless the conversation has its own.
  public var model = "sonnet"
  /// The auto-compact window, in tokens, that sbd sets as `CLAUDE_CODE_AUTO_COMPACT_WINDOW` when it starts or
  /// resumes a Manager conversation. Claude Code compacts about 33k tokens below the window, so 183000 compacts
  /// near 150k. Claude Code reads a value under 100000 as 100000. With 0, sbd sets nothing and claude uses its own window.
  public var autoCompactWindow = 183_000

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = ManagerSettings()
    model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
    autoCompactWindow = try c.decodeIfPresent(Int.self, forKey: .autoCompactWindow) ?? d.autoCompactWindow
  }

  /// Sets the window in the environment of a Manager conversation's claude. It replaces a value that
  /// config.json's `env` set. A window of 0 or less leaves the environment as it is.
  public func apply(to env: inout [String: String]) {
    guard autoCompactWindow > 0 else { return }
    env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = String(autoCompactWindow)
  }
}

extension Manager {
  /// The model that sbd passes with `--model` when it starts claude for a session, or nil for claude's default.
  /// A model stored on the session wins. Otherwise a Manager conversation runs `managerModel`, and every other
  /// kind runs claude's default.
  public static func launchModel(for kind: SessionKind, stored: String?, managerModel: String) -> String? {
    if let stored { return stored }
    return kind == .manager ? managerModel : nil
  }

  /// Why `model` can't be the Manager's model, or nil when it can. claude reads a value that starts with a dash
  /// as an option.
  public static func modelProblem(_ model: String) -> String? {
    if model.isEmpty { return "the model needs a name, such as sonnet" }
    if model.contains(where: \.isWhitespace) { return "the model name can't contain spaces" }
    if model.hasPrefix("-") { return "the model name can't start with a dash" }
    return nil
  }
}
