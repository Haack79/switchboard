import Foundation
import SwitchboardCore

extension BoardModel {
  /// Highlights the session, or removes its highlight when `on` is false. The request names the value, so a
  /// second click sends the same value and changes nothing.
  func setHighlighted(_ id: String, _ on: Bool) {
    perform("highlight", ["session": .string(id), "highlighted": .bool(on)])
  }
}
