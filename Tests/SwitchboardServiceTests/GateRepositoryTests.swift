import Foundation
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

/// The gate's read of a work session's repository. A session that sbd read and found off GitHub can't be in the
/// gate's repository, so it doesn't keep the gate open. A lookup that failed read nothing, so its session is unknown
/// and opens the gate.
struct GateRepositoryTests {
  static let gate = Schedule.Gate(group: "g", repo: "acme/widgets", target: 1, template: "t", rubric: "r")

  enum Folder: CaseIterable {
    /// The session's folder is gone, so the checkout lookup fails.
    case gone
    /// The session's checkout is gone, so the origin lookup fails.
    case checkoutGone
    /// A repo without an origin remote, which the lookups read.
    case noOrigin
  }

  private func git(_ args: String...) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw TestError("git \(args) exited \(p.terminationStatus)") }
  }

  private func session(_ folder: Folder, in home: String) throws -> Session {
    let path = "\(home)/work"
    var s = Session(id: "w1", name: "w1", cwd: path, claudeSessionId: "u-w1", created: 5)
    s.started = true
    s.group = Self.gate.group
    switch folder {
    case .gone: break
    case .checkoutGone: s.repo = "\(home)/checkout"
    case .noOrigin: try git("init", "-q", path)
    }
    return s
  }

  /// The session's row once no lookup runs.
  private func settledRow(_ service: Service, _ s: Session) throws -> QueueStatus.Row {
    service.queue.sync { service.entries[s.id] = Service.Entry(session: s) }
    for _ in 0..<300 {
      // Each read starts the lookup that the row still lacks, so a read that leaves no lookup running is final.
      let row = service.queue.sync { () -> QueueStatus.Row? in
        let row = service.queueRows(subjects: ([], []), gate: Self.gate).first { $0.id == s.id }
        return service.checkoutLookups.isEmpty && service.repositoryLookups.isEmpty ? row : nil
      }
      if let row { return row }
      usleep(100_000)
    }
    throw TestError("the lookups of \(s.cwd) never ended")
  }

  @Test(.timeLimit(.minutes(1)), arguments: Folder.allCases)
  func onlyALookupThatReadTheFolderLeavesASessionOffGitHub(_ folder: Folder) throws {
    try withService { service, home in
      let row = try settledRow(service, try session(folder, in: home.path))
      let status = QueueStatus.compute([row], gate: Self.gate)

      #expect(row.repository == nil, "\(row)")
      switch folder {
      case .gone, .checkoutGone:
        #expect(!row.repositoryRead, "\(row)")
        #expect(status.unknown.map(\.id) == [row.id], "\(status)")
      case .noOrigin:
        #expect(row.repositoryRead, "\(row)")
        #expect(status.decision == .topup(k: 1), "\(status)")
      }
    }
  }
}

private struct TestError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
