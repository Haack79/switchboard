import Foundation
import SwitchboardCore

/// Moves one session to another Claude account through sbd's `account-move`,
/// the request that `sb account move --session` sends.
extension BoardModel {
  /// Asks sbd whether the session can move, then moves it, asks the user
  /// first, or shows sbd's reason. The dry run sends `stop` so that a running
  /// claude does not refuse it. A dry run stops nothing.
  func requestAccountMove(_ id: String, to folder: String) {
    guard let session = summary(id) else { return }
    let args: [String: JSON] = [
      "account": .string(folder), "sessions": [.string(id)], "stop": true, "dryRun": true,
    ]
    perform("account-move", args) { value in
      guard let plan = try? JSONCoding.convert(value, to: AccountMove.self) else { return }
      switch SessionAccountMove.decide(session: session, target: folder, plan: plan) {
      case .refuse(let reason): self.actionError = reason
      case .confirm(let move): self.confirmingAccountMove = move
      case .move: self.sendAccountMove(id, name: session.name, to: folder, stop: false)
      }
    }
  }

  func confirmAccountMove(_ move: SessionAccountMove) {
    confirmingAccountMove = nil
    sendAccountMove(move.session, name: move.name, to: move.folder, stop: move.stop)
  }

  /// A move without `stop` lets sbd refuse a claude that started after the
  /// dry run, so the app never stops a claude that the user did not agree to stop.
  private func sendAccountMove(_ id: String, name: String, to folder: String, stop: Bool) {
    var args: [String: JSON] = ["account": .string(folder), "sessions": [.string(id)]]
    if stop { args["stop"] = true }
    perform("account-move", args) { value in
      guard let result = try? JSONCoding.convert(value, to: AccountMove.self),
        let blocked = result.blocked.first
      else { return }
      self.actionError = SessionAccountMove.refusal(name, to: folder, blocked.reason)
    }
  }

  /// Shows the Board with the session's card in its group's lane, where the
  /// lane's account menu sets the group's account. A group chat has no card.
  func showGroupOnBoard(_ session: SessionSummary) {
    UserDefaults.standard.set(BoardLanes.group.rawValue, forKey: BoardLanes.storageKey)
    show(.board)
    if session.kind == .work { boardFocus = session.id }
  }
}
