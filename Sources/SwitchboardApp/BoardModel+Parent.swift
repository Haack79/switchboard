import Foundation
import SwitchboardCore

extension BoardModel {
  static let unlinkHelp =
    "The parent stops hearing what changed in this session. Its group, account, and waits stay. Edit > Undo links it again."

  /// The name of the session's parent when the parent is a live session and the session is not a follow-up, and nil
  /// otherwise. The sidebar nests a session under the same parent.
  func linkedParentName(of s: SessionSummary) -> String? {
    let names = sessionNames
    return SessionTree.parentID(
      of: s.id, parent: s.parent, followup: s.followup, isKnown: { names.entry($0).map { !$0.removed } ?? false }
    ).map(names.name)
  }

  /// Unlinks the session from its parent. When sbd accepts, Edit > Undo links it to that parent again.
  func unlinkParent(_ id: String) {
    guard let parent = allSessions.first(where: { $0.id == id })?.parent else { return }
    let name = sessionNames.name(parent)
    sendParent(id, nil) { [weak self] in self?.registerFlip(id, parent: parent, name: name, relinks: true) }
  }

  /// Sends the `parent` request that moves the session to `parent`, or that unlinks it when `parent` is nil.
  private func sendParent(_ id: String, _ parent: String?, then: (() -> Void)? = nil) {
    var args: [String: JSON] = ["session": .string(id)]
    if let parent { args["parent"] = .string(parent) } else { args["clear"] = true }
    perform("parent", args, then: { _ in then?() })
  }

  /// Registers the undo of the last change: a relink to `parent` when `relinks` is true, and an unlink otherwise.
  /// UndoManager puts a registration made while it undoes on the redo stack, and one made while it redoes on the
  /// undo stack. The handler therefore registers the opposite change before it sends, because the request answers
  /// after the undo ends.
  private func registerFlip(_ id: String, parent: String, name: String, relinks: Bool) {
    registerUndo(named: "Unlink from \(name)") { model in
      model.registerFlip(id, parent: parent, name: name, relinks: !relinks)
      model.sendParent(id, relinks ? parent : nil)
    }
  }
}
