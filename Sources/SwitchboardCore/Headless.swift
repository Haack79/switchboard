import Foundation
import os

/// A one-shot `claude -p` turn that can only answer: no tools, no MCP
/// servers, no settings, and no saved session. Its answer is JSON that a
/// schema shapes.
public enum Headless {
  /// The arguments of the `claude` command, after the program.
  public static func arguments(model: String, schema: JSON, system: String) -> [String] {
    [
      "-p", "--model", model, "--output-format", "json", "--json-schema", schema.text, "--tools", "",
      "--strict-mcp-config", "--no-session-persistence", "--setting-sources", "", "--disable-slash-commands",
      "--system-prompt", system,
    ]
  }

  /// Runs `claude` with the arguments and the input on stdin, in the folder,
  /// and returns what it printed. It ends the process after `timeout`
  /// seconds, or within 100 ms of `cancelled` returning true, and then throws.
  public static func run(
    claude: String, arguments: [String], input: String, env: [String: String], folder: String,
    timeout: Double, cancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> String {
    if cancelled() { throw APIError("cancelled") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: claude)
    p.arguments = arguments
    p.environment = env
    p.currentDirectoryURL = URL(fileURLWithPath: folder)
    let stdin = Pipe()
    let stdout = Pipe()
    p.standardInput = stdin
    p.standardOutput = stdout
    p.standardError = FileHandle.nullDevice
    // A process that ends before it reads all of its input makes the write fail with EPIPE.
    // Without this flag, that write raises SIGPIPE, which ends a process that doesn't ignore it.
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    try p.run()
    let ending = OSAllocatedUnfairLock<RunEnd?>(initialState: nil)
    let deadline = DispatchTime.now() + timeout
    let monitor = DispatchSource.makeTimerSource(queue: .global())
    monitor.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
    monitor.setEventHandler {
      let reason: RunEnd? = cancelled() ? .cancelled : DispatchTime.now() >= deadline ? .timedOut : nil
      guard let reason else { return }
      ending.withLock { end in
        guard end == nil else { return }
        end = reason
        if p.isRunning { p.terminate() }
      }
    }
    monitor.resume()
    try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
    try? stdin.fileHandleForWriting.close()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    monitor.cancel()
    let end = ending.withLock { end in
      if end == nil { end = .exited }
      return end
    }
    switch end {
    case .cancelled: throw APIError("cancelled")
    case .timedOut: throw APIError("timed out after \(Int(timeout)) s")
    case .exited, nil: break
    }
    guard p.terminationStatus == 0 else {
      throw APIError(
        "claude exited with status \(p.terminationStatus): \(oneLine(String(decoding: output, as: UTF8.self), max: 200))"
      )
    }
    return String(decoding: output, as: UTF8.self)
  }

  private enum RunEnd: Sendable { case exited, timedOut, cancelled }

  /// The JSON object that the output of `claude -p --output-format json` answers with.
  public static func answer(_ output: String) throws -> [String: JSON] {
    guard let envelope = JSON.parse(output) else {
      throw APIError("claude printed no JSON: \(oneLine(output, max: 200))")
    }
    if envelope["is_error"]?.bool == true {
      throw APIError("claude failed: \(oneLine(envelope["result"]?.string ?? output, max: 200))")
    }
    let payload =
      envelope["structured_output"]
      ?? envelope["result"]?.string.flatMap { JSON.parse(unfenced($0)) }
    guard let object = payload?.object else { throw APIError("claude's answer holds no JSON object") }
    return object
  }

  /// The text without a Markdown code fence around it.
  static func unfenced(_ text: String) -> String {
    var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
    if lines.first?.hasPrefix("```") == true, lines.last?.hasPrefix("```") == true, lines.count >= 2 {
      lines.removeFirst()
      lines.removeLast()
    }
    return lines.joined(separator: "\n")
  }
}
