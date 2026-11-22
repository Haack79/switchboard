import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// Risk 1 and Risk 3 guards that read a stored or configured folder. Each test uses a Codex folder that keeps
/// its .claude.json, so the older checks for a Claude login let it through and only the Codex check refuses it.
@Suite struct CodexFolderGuardTests {
  /// A `Service` in a temporary home that never loads. Its config lists the Claude account `claude` and the
  /// Codex home `cx`, and `cx` holds a Claude login, which makes it both kinds.
  private func withAccounts(
    config extra: [String: JSON] = [:], _ body: (Service, Home, _ claude: String, _ cx: String) throws -> Void
  ) throws {
    let home = Home(path: try makeShortTempFolder())
    defer { try? FileManager.default.removeItem(atPath: home.path) }
    let claude = "\(home.path)/claude"
    let cx = "\(home.path)/cx"
    for folder in [claude, cx] {
      try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
      try Data("{}".utf8).write(to: URL(fileURLWithPath: "\(folder)/.claude.json"))
    }
    let config: [String: JSON] = [
      "claude": "/usr/bin/false", "tmux": "/usr/bin/true", "sessionNames": ["enabled": false],
      "claudeConfigDirs": [.string(claude)], "codexHomes": [.string(cx)],
    ]
    try JSON.object(config.merging(extra) { $1 }).text.write(toFile: home.config, atomically: true, encoding: .utf8)
    try body(try Service(home: home, sbPath: "/usr/bin/true"), home, claude, cx)
  }

  @Test(.timeLimit(.minutes(1)))
  func aCodexHomesEntryThatHoldsAClaudeLoginDoesNotResolveByPath() throws {
    try withAccounts { service, _, _, cx in
      for ref in [cx, cx + "/"] {
        let error = #expect(throws: APIError.self) { try service.queue.sync { try service.resolveAccount(ref) } }
        #expect("\(error.map { "\($0)" } ?? "")".contains("Codex"), "\(ref)")
      }
    }
  }

  /// A Mac's file system usually ignores case, so ~/.Codex-x can be the folder ~/.codex-x.
  @Test(.timeLimit(.minutes(1)))
  func aFolderNamedLikeACodexFolderInAnotherCaseDoesNotResolveAsAClaudeAccount() throws {
    try withAccounts { service, home, _, _ in
      let folder = "\(home.path)/.Codex-x"
      try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
      try Data("{}".utf8).write(to: URL(fileURLWithPath: "\(folder)/.claude.json"))

      #expect(throws: APIError.self) { try service.queue.sync { try service.resolveClaudeAccount(folder) } }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aGroupWhoseAccountIsACodexHomeGivesNewSessionsNoAccount() throws {
    try withAccounts { service, _, claude, cx in
      var session = makeSession("s1", name: "s1")
      session.group = "g"
      let bound = service.queue.sync { () -> [String?] in
        service.groups["g"] = SessionGroup(id: "g", name: "G", created: 0, account: cx)
        let codex = service.accountGroupForNew(session)?.account
        service.groups["g"] = SessionGroup(id: "g", name: "G", created: 0, account: claude)
        return [codex, service.accountGroupForNew(session)?.account]
      }

      #expect(bound == [nil, claude])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aChosenAccountThatIsACodexHomeIsIgnored() throws {
    try withAccounts { service, home, _, cx in
      try cx.write(toFile: home.activeAccount, atomically: true, encoding: .utf8)

      let active = service.queue.sync {
        service.loadChosenAccount()
        return service.activeAccount.folder
      }

      #expect(active != ClaudeAccount.normalize(cx))
    }
  }

  /// `headlessEnv` itself falls back, so a caller that passes a Codex folder still runs claude under Claude.
  @Test(.timeLimit(.minutes(1)))
  func aHeadlessTurnUnderACodexHomeRunsUnderTheTriageAccount() throws {
    let triage = "\(NSTemporaryDirectory())placeholder"
    try withAccounts(config: ["triage": ["account": .string(triage)]]) { service, _, _, cx in
      let env = service.queue.sync {
        service.headlessEnv(session: nil, account: ClaudeAccount(folder: cx), base: ["CLAUDE_CONFIG_DIR": cx])
      }

      #expect(env["CLAUDE_CONFIG_DIR"] == ClaudeAccount.normalize(triage))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aHeadlessTurnUnderACodexHomeWithACodexTriageAccountRunsUnderTheActiveAccount() throws {
    try withAccounts { service, home, claude, cx in
      try claude.write(toFile: home.activeAccount, atomically: true, encoding: .utf8)
      let env = service.queue.sync {
        service.loadChosenAccount()
        return service.headlessEnv(session: nil, account: nil, base: ["CLAUDE_CONFIG_DIR": cx])
      }

      #expect(env["CLAUDE_CONFIG_DIR"] == claude)
    }
  }

  /// The trust entry would go into the Codex folder's .claude.json.
  @Test(.timeLimit(.minutes(1)))
  func aManagerOnACodexHomeGetsNoTrustEntry() throws {
    try withAccounts { service, home, _, cx in
      try FileManager.default.createDirectory(atPath: home.managerFolder, withIntermediateDirectories: true)
      var session = makeSession("m1", name: "Manager")
      session.manager = true
      session.cwd = home.managerFolder
      session.claudeConfigDir = cx
      service.queue.sync {
        service.entries["m1"] = Service.Entry(session: session)
        service.trustOwnFolder("m1")
      }

      #expect(try String(contentsOfFile: "\(cx)/.claude.json", encoding: .utf8) == "{}")
    }
  }
}
