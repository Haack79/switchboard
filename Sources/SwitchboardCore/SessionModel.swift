/// The model that a session stores when it is created, and the model that sbd passes with `--model` when it starts
/// claude for the session. Neither rule reads the parent session's model.
public enum SessionModel {
  /// The model that a new session stores. The caller's model wins. Otherwise a Manager conversation stores none,
  /// and every other kind stores `workModel`.
  public static func stored(kind: SessionKind, requested: String?, workModel: String?) -> String? {
    if let requested { return requested }
    return kind == .manager ? nil : workModel
  }

  /// The model that sbd passes with `--model`, or nil for claude's default. A model stored on the session wins.
  /// Otherwise a Manager conversation runs `coordinatorModel`, and every other kind runs claude's default.
  public static func launch(kind: SessionKind, stored: String?, coordinatorModel: String) -> String? {
    if let stored { return stored }
    return kind == .manager ? coordinatorModel : nil
  }
}
