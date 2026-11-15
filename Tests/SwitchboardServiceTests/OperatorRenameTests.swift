import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// A `Service` in a temporary home whose state holds an operator named `operatorName` and a work session. The
/// service never loads, so it starts no tmux server and no claude.
private func withOperator(named operatorName: String, _ body: (Service) throws -> Void) throws {
  let home = Home(path: try makeShortTempFolder())
  defer { try? FileManager.default.removeItem(atPath: home.path) }
  let service = try Service(home: home, sbPath: "/usr/bin/true")
  service.queue.sync {
    var op = Session(id: "op", name: operatorName, cwd: "/tmp", claudeSessionId: "c-op", created: 0)
    op.isOperator = true
    op.manager = true
    service.entries[op.id] = Service.Entry(session: op)
    service.entries["work"] = Service.Entry(
      session: Session(id: "work", name: "work", cwd: "/tmp", claudeSessionId: "c-work", created: 0))
  }
  try body(service)
}

@Suite struct OperatorRenameTests {
  /// An older sbd let the user rename the operator, which broke `sb get Operator`.
  @Test(.timeLimit(.minutes(1)))
  func aRenamedOperatorCanTakeItsNameBack() throws {
    try withOperator(named: "Ops") { service in
      #expect(throws: Never.self) {
        try service.queue.sync { try service.refuseRename("op", to: Manager.operatorName) }
      }
    }
  }

  /// An older sbd also let another session take the name, and a second session with it breaks `sb get Operator`.
  @Test(.timeLimit(.minutes(1)))
  func aRenamedOperatorCannotTakeItsNameBackWhileAnotherSessionHoldsIt() throws {
    try withOperator(named: "Ops") { service in
      service.queue.sync { service.entries["work"]?.session.name = Manager.operatorName }
      do {
        try service.queue.sync { try service.refuseRename("op", to: Manager.operatorName) }
        Issue.record("the operator took a name that the work session holds")
      } catch {
        #expect("\(error)".contains("Rename that session first"), "\(error)")
      }
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["Ops", "operator", "Other"])
  func theOperatorTakesNoOtherName(_ name: String) throws {
    try withOperator(named: Manager.operatorName) { service in
      do {
        try service.queue.sync { try service.refuseRename("op", to: name) }
        Issue.record("the operator was renamed to \(name)")
      } catch {
        #expect("\(error)".contains("keeps the name \(Manager.operatorName)"), "\(error)")
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func anotherSessionCannotTakeTheOperatorsName() throws {
    try withOperator(named: Manager.operatorName) { service in
      do {
        try service.queue.sync { try service.refuseRename("work", to: Manager.operatorName) }
        Issue.record("the work session took the operator's name")
      } catch {
        #expect("\(error)".contains("belongs to the background operator"), "\(error)")
      }
    }
  }
}
