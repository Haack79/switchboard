import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// A shell that dies must not leave a process behind. A leftover process works in the shell's working folder.
/// A session's delete refuses while any process works in its folder.
@Suite struct RemoteShellOrphanTests {
  static let trials = 40
  static let commandTimeout = 0.5

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms, [SIGTERM, SIGKILL])
  func aShellThatDiesAsATimedCommandStartsLeavesNoProcess(_ program: String, _ signal: Int32) throws {
    try withRemoteShellTempFolder { folder in
      let token = String(repeating: "ab", count: 16)
      let boot = Data(RemoteShellProtocol.bootScript(token: token).utf8)
      let request = try RemoteShellProtocol.request(
        seq: 1, argv: ["/bin/sleep", "0.2"], env: nil, input: nil, timeout: Self.commandTimeout)
      for _ in 0..<Self.trials {
        try Self.killAsCommandStarts(program, signal, in: folder, boot: boot, request: request)
      }
      let left = Self.waitForNoUsers(of: folder)
      #expect(left.isEmpty, "processes still work in the shell's folder: \(left.map(\.pid))")
    }
  }

  /// The timeout still ends a program after the shell dies. Under SIGTERM, the shell's EXIT trap removes `$sb_d`
  /// first, so the timeout's subshell can't create `$sb_d/t`.
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms, [SIGTERM, SIGKILL])
  func theTimeoutEndsTheProgramAfterTheShellDies(_ program: String, _ signal: Int32) throws {
    try withRemoteShellTempFolder { folder in
      let boot = Data(RemoteShellProtocol.bootScript(token: String(repeating: "ab", count: 16)).utf8)
      let request = try RemoteShellProtocol.request(
        seq: 1, argv: ["/bin/sleep", "30"], env: nil, input: nil, timeout: Self.commandTimeout)
      let (shell, stdin, stdout) = try Self.start(program, in: folder, boot: boot)
      defer { try? stdout.fileHandleForReading.close() }
      stdin.fileHandleForWriting.write(request)
      let started = waitUntil(seconds: 5) { Processes.using(folder).count >= 3 }
      kill(shell.processIdentifier, signal)
      shell.waitUntilExit()
      let left = Self.waitForNoUsers(of: folder)
      try #require(started, "the command never started in the shell's folder")
      #expect(left.isEmpty, "processes still work in the shell's folder: \(left.map(\.pid))")
    }
  }

  /// A host whose shell can't run `sleep` still ends a timed command, at once, rather than letting it run with
  /// no timeout.
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aTimeoutWhoseSleepFailsEndsTheProgram(_ program: String) throws {
    try withRemoteShellTempFolder { folder in
      for tool in ["/usr/bin/mktemp", "/usr/bin/stat", "/usr/bin/base64", "/usr/bin/wc", "/usr/bin/head", "/bin/rm"] {
        try FileManager.default.createSymbolicLink(
          atPath: folder + "/" + (tool as NSString).lastPathComponent, withDestinationPath: tool)
      }
      let t = try TestShell.start(program, environment: ["PATH": folder])
      defer { t.shell.close() }
      let started = Date()
      let r = try t.run(["/bin/sleep", "30"], timeout: 10, deadline: 30)
      #expect(r.status == 143)
      #expect(Date().timeIntervalSince(started) < 8)
    }
  }

  /// Waits until no process works in `folder`, or until the timeout and its 2 s grace have long passed. It kills
  /// what is left and returns it.
  private static func waitForNoUsers(of folder: String) -> [FolderUser] {
    let deadline = Date().addingTimeInterval(commandTimeout + 8)
    var left = Processes.using(folder)
    while !left.isEmpty, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.2)
      left = Processes.using(folder)
    }
    for user in left { kill(pid_t(user.pid), SIGKILL) }
    return left
  }

  /// Signals the shell up to 4 ms after the request, while `sb_run` starts the command's timeout. It does not
  /// use `RemoteShell`, because `RemoteShell.run` blocks until the answer. The request would then go out from
  /// another thread, and the signal could not be timed against its write.
  private static func killAsCommandStarts(
    _ program: String, _ signal: Int32, in folder: String, boot: Data, request: Data
  ) throws {
    let (shell, stdin, stdout) = try Self.start(program, in: folder, boot: boot)
    defer { try? stdout.fileHandleForReading.close() }
    stdin.fileHandleForWriting.write(request)
    Thread.sleep(forTimeInterval: Double.random(in: 0..<0.004))
    try stdin.fileHandleForWriting.close()
    kill(shell.processIdentifier, signal)
    shell.waitUntilExit()
  }

  /// Starts `program` in `folder`, sends it `boot`, and returns once the shell prints its ready line. The caller
  /// closes the returned stdout.
  private static func start(_ program: String, in folder: String, boot: Data) throws -> (Process, Pipe, Pipe) {
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: program)
    shell.currentDirectoryURL = URL(fileURLWithPath: folder)
    let stdin = Pipe()
    let stdout = Pipe()
    shell.standardInput = stdin
    shell.standardOutput = stdout
    shell.standardError = FileHandle.nullDevice
    try shell.run()
    stdin.fileHandleForWriting.write(boot)
    var answer = Data()
    while !answer.contains(UInt8(ascii: "\n")) {
      let chunk = stdout.fileHandleForReading.availableData
      try #require(!chunk.isEmpty, "\(program) ended before its ready line")
      answer.append(chunk)
    }
    return (shell, stdin, stdout)
  }
}
