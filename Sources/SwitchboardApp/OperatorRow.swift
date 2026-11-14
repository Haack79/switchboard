import SwiftUI
import SwitchboardCore

/// The sidebar's Operator section, which shows only while the operator exists.
struct OperatorRow: View {
  @EnvironmentObject var model: BoardModel
  let activeAccount: String

  var body: some View {
    if let op = model.operatorSession {
      Section("Operator") {
        SessionRow(session: op, activeAccount: activeAccount, hoverCard: model.hoverCard).tag(op.id)
      }
    }
  }
}
