import Foundation
import Testing
import os

@testable import SwitchboardCore

/// A CI runner has 3 CPUs and starts processes several times slower than a laptop does.
private let scale: Double = ProcessInfo.processInfo.environment["CI"] == nil ? 1 : 3

/// A script that writes its pid to the file and then becomes `sleep 30` with that pid. It never reads stdin. The
/// `exec` matters: a shell that ran `sleep` as a child would leave it holding stdout open after SIGTERM.
private func neverEnds(pidFile: String) -> String { "echo $$ > '\(pidFile)'; exec sleep 30" }

/// Runs the script with `/bin/sh -c` through `Headless.run`, in `folder`.
private func run(
  _ script: String, input: String = "", env: [String: String] = ProcessInfo.processInfo.environment,
  folder: String, timeout: Double = 30, cancelled: @escaping @Sendable () -> Bool = { false }
) throws -> String {
  try Headless.run(
    claude: "/bin/sh", arguments: ["-c", script], input: input, env: env, folder: folder, timeout: timeout,
    cancelled: cancelled)
}

/// The pid that a script wrote to the file, or nil when it wrote none.
private func writtenPid(_ file: String) -> pid_t? {
  guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
  return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Whether a process with the pid still exists. `Headless.run` reaps the process before it returns, so a process
/// that it ended no longer exists.
private func exists(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

/// The seconds since `start`.
private func since(_ start: Date) -> Double { Date().timeIntervalSince(start) }

/// The process runner behind the triage summary, the merge brief, the plan update, and the quick ask.
@Suite(.timeLimit(.minutes(1))) struct HeadlessRunTests {
  // MARK: A normal run

  @Test func echoesTheInputAndReturnsWhatTheScriptPrinted() throws {
    let folder = try scratchFolder()

    let output = try run("cat", input: "hello\nworld", folder: folder)

    #expect(output == "hello\nworld")
  }

  @Test func runsInTheFolder() throws {
    let folder = try scratchFolder()

    let output = try run("pwd -P", folder: folder)

    let resolved = try #require(realpath(folder, nil))
    defer { free(resolved) }
    #expect(output.trimmingCharacters(in: .newlines) == String(cString: resolved))
  }

  @Test func passesTheEnvironment() throws {
    let folder = try scratchFolder()

    let output = try run(#"printf %s "$HEADLESS_VALUE""#, env: ["HEADLESS_VALUE": "from the caller"], folder: folder)

    #expect(output == "from the caller")
  }

  /// Process raises an exception that Swift can't catch for a NUL, which would end sbd.
  @Test func refusesANulInAnArgumentOrTheEnvironment() throws {
    let folder = try scratchFolder()

    #expect(throws: Headless.NotStarted.self) { try run("echo a\u{0}b", folder: folder) }
    #expect(throws: Headless.NotStarted.self) { try run("echo hi", env: ["X": "a\u{0}b"], folder: folder) }
    #expect(throws: Headless.NotStarted.self) { try run("echo hi", env: ["X\u{0}Y": "v"], folder: folder) }
  }

  @Test func aNonZeroExitThrowsWithTheStatusAndTheOutput() throws {
    let folder = try scratchFolder()

    let error = #expect(throws: Headless.ExitError.self) { try run("echo partial answer; exit 3", folder: folder) }

    #expect(error?.status == 3)
    #expect(error?.output == "partial answer\n")
    #expect(error?.description.contains("status 3") == true, "\(String(describing: error))")
    #expect(error?.description.contains("partial answer") == true, "\(String(describing: error))")
  }

  /// A process that ends before it reads all of its input makes the write of the rest fail. That failure must not
  /// end the caller with SIGPIPE, and the run still returns what the process printed.
  @Test func aScriptThatReadsPartOfALargeInputAndExitsReturnsItsOutput() throws {
    let folder = try scratchFolder()
    let input = String(repeating: "x", count: 1_000_000)

    let output = try run("head -c 10", input: input, folder: folder)

    #expect(output == String(repeating: "x", count: 10))
  }

  // MARK: Timeout

  @Test func aScriptThatNeverEndsTimesOutWithinTwoSeconds() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"
    let start = Date()

    let error = #expect(throws: Headless.TimedOut.self) {
      try run(neverEnds(pidFile: pidFile), folder: folder, timeout: 0.5)
    }

    #expect(error?.description.contains("timed out") == true, "\(String(describing: error))")
    #expect(since(start) < 2 * scale)
  }

  @Test func aTimeoutLeavesNoProcess() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"

    _ = try? run(neverEnds(pidFile: pidFile), folder: folder, timeout: 0.5)

    let pid = try #require(writtenPid(pidFile))
    #expect(!exists(pid))
  }

  // MARK: Cancel

  @Test func aCancelDuringTheRunThrowsCancelledWithinTwoSeconds() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"
    let start = Date()

    let error = #expect(throws: APIError.self) {
      try run(neverEnds(pidFile: pidFile), folder: folder, cancelled: { since(start) > 0.3 })
    }

    #expect(error?.description.contains("cancelled") == true, "\(String(describing: error))")
    #expect(since(start) < 2 * scale)
  }

  @Test func aCancelDuringTheRunLeavesNoProcess() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"
    let start = Date()

    _ = try? run(neverEnds(pidFile: pidFile), folder: folder, cancelled: { since(start) > 0.3 })

    let pid = try #require(writtenPid(pidFile))
    #expect(!exists(pid))
  }

  /// A cancel that arrives before the run starts no process. `NotStarted` tells `headlessCall` to record no call.
  @Test func aCancelBeforeTheRunThrowsCancelledAndLeavesNoProcess() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"
    let start = Date()

    let error = #expect(throws: Headless.NotStarted.self) {
      try run(neverEnds(pidFile: pidFile), folder: folder, cancelled: { true })
    }

    #expect(error?.description.contains("cancelled") == true, "\(String(describing: error))")
    #expect(since(start) < 2 * scale)
    #expect(writtenPid(pidFile).map(exists) != true)
  }

  /// The stdin write blocks once the pipe's buffer fills, because the script never reads. The end of the run must
  /// still come from the cancel or the timeout, and the failed write of the rest must not crash the caller.
  @Test(arguments: [true, false])
  func aRunThatEndsWhileItsLargeInputIsUnreadThrowsAndDoesNotCrash(_ byCancel: Bool) throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"
    let input = String(repeating: "q", count: 1_000_000)
    let start = Date()

    let error = #expect(throws: (any Error).self) {
      try run(
        neverEnds(pidFile: pidFile), input: input, folder: folder, timeout: byCancel ? 30 : 0.5,
        cancelled: { byCancel && since(start) > 0.3 })
    }

    #expect(byCancel ? error is APIError : error is Headless.TimedOut)
    let expected = byCancel ? "cancelled" : "timed out"
    #expect(error.map { "\($0)" }?.contains(expected) == true, "\(String(describing: error))")
    #expect(since(start) < 2 * scale)
    #expect(writtenPid(pidFile).map(exists) != true)
  }

  // MARK: The monitor

  @Test func aQuickRunReturnsNormallyWhenNothingCancels() throws {
    let folder = try scratchFolder()

    let output = try run("sleep 0.1; echo done", folder: folder, cancelled: { false })

    #expect(output == "done\n")
  }

  /// The monitor that checks `cancelled` stops once the process exits, so no check, and no terminate, comes later.
  @Test func theMonitorStopsCheckingOnceTheRunEnds() throws {
    let folder = try scratchFolder()
    let checks = OSAllocatedUnfairLock(initialState: 0)
    _ = try run(
      "sleep 0.3; echo done", folder: folder,
      cancelled: {
        checks.withLock { $0 += 1 }
        return false
      })
    let afterRun = checks.withLock { $0 }

    usleep(500_000)

    #expect(checks.withLock { $0 } == afterRun)
  }

  /// A cancel that turns true only after the run returned changes nothing about that run's result.
  @Test func aCancelAfterTheRunEndedDoesNotChangeTheResult() throws {
    let folder = try scratchFolder()
    let returned = OSAllocatedUnfairLock(initialState: false)

    let output = try run("echo done", folder: folder, cancelled: { returned.withLock { $0 } })
    returned.withLock { $0 = true }
    usleep(300_000)

    #expect(output == "done\n")
  }
}
