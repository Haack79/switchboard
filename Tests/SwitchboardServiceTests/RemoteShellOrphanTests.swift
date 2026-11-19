import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// A shell that dies just as a timed command starts must not leave a process behind. A leftover process
/// works in the shell's working folder. A session's delete refuses while any process works in its folder.
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
      // A process that the command started may run until the timeout and the 2 s grace end.
      let deadline = Date().addingTimeInterval(Self.commandTimeout + 8)
      var left = Processes.using(folder)
      while !left.isEmpty, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.2)
        left = Processes.using(folder)
      }
      for user in left { kill(pid_t(user.pid), SIGKILL) }
      #expect(left.isEmpty, "processes still work in the shell's folder: \(left.map(\.pid))")
    }
  }

  /// Signals the shell up to 4 ms after the request, while `sb_run` starts the command's timeout. It does not
  /// use `RemoteShell`, because `RemoteShell.run` blocks until the answer. The request would then go out from
  /// another thread, and the signal could not be timed against its write.
  private static func killAsCommandStarts(
    _ program: String, _ signal: Int32, in folder: String, boot: Data, request: Data
  ) throws {
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: program)
    shell.currentDirectoryURL = URL(fileURLWithPath: folder)
    let stdin = Pipe()
    let stdout = Pipe()
    shell.standardInput = stdin
    shell.standardOutput = stdout
    shell.standardError = FileHandle.nullDevice
    try shell.run()
    defer { try? stdout.fileHandleForReading.close() }
    stdin.fileHandleForWriting.write(boot)
    var answer = Data()
    while !answer.contains(UInt8(ascii: "\n")) {
      let chunk = stdout.fileHandleForReading.availableData
      try #require(!chunk.isEmpty, "\(program) ended before its ready line")
      answer.append(chunk)
    }
    stdin.fileHandleForWriting.write(request)
    Thread.sleep(forTimeInterval: Double.random(in: 0..<0.004))
    try stdin.fileHandleForWriting.close()
    kill(shell.processIdentifier, signal)
    shell.waitUntilExit()
  }
}
