import Foundation

/// The `manager` settings in config.json.
public struct ManagerSettings: Codable, Equatable, Sendable {
  /// The model that a Manager conversation runs, unless the conversation has its own.
  public var model = "sonnet"

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    model = try c.decodeIfPresent(String.self, forKey: .model) ?? ManagerSettings().model
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
