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
    // Process raises an Objective-C exception for a NUL. Swift can't catch it, and it would end sbd.
    if (arguments + Array(env.keys) + Array(env.values)).contains(where: \.hasNul) {
      throw APIError("claude can't run with a NUL character in its arguments or environment")
    }
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
    // A global queue gets no thread while callers wait on every thread of Swift's cooperative pool.
    let monitor = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Headless.monitor"))
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
    let text = String(decoding: output, as: UTF8.self)
    guard p.terminationStatus == 0 else { throw ExitError(status: p.terminationStatus, output: text) }
    return text
  }

  /// What `run` throws when `claude` exits with a nonzero status. claude exits with status 1 after an error
  /// envelope, which still reports the tokens that the call spent, so the error keeps what claude printed.
  public struct ExitError: Error, CustomStringConvertible {
    public let status: Int32
    public let output: String

    public var description: String { "claude exited with status \(status): \(oneLine(output, max: 200))" }
  }

  private enum RunEnd: Sendable { case exited, timedOut, cancelled }

  /// The output with the model and the tokens that its envelope reports. It reads them even when the answer is an
  /// error or holds no JSON object, because the call spent the tokens either way.
  public static func reply(_ output: String) -> HeadlessReply {
    guard let envelope = JSON.parse(output)?.object else { return HeadlessReply(output: output) }
    if let models = envelope["modelUsage"]?.object, !models.isEmpty {
      let usage = models.values.map {
        HeadlessUsage(
          input: $0["inputTokens"]?.int ?? 0, output: $0["outputTokens"]?.int ?? 0,
          cacheRead: $0["cacheReadInputTokens"]?.int ?? 0, cacheWrite: $0["cacheCreationInputTokens"]?.int ?? 0)
      }.reduce(HeadlessUsage(), +)
      return HeadlessReply(output: output, usage: usage, model: models.keys.sorted().joined(separator: "+"))
    }
    guard let usage = envelope["usage"]?.object else { return HeadlessReply(output: output) }
    return HeadlessReply(
      output: output,
      usage: HeadlessUsage(
        input: usage["input_tokens"]?.int ?? 0, output: usage["output_tokens"]?.int ?? 0,
        cacheRead: usage["cache_read_input_tokens"]?.int ?? 0,
        cacheWrite: usage["cache_creation_input_tokens"]?.int ?? 0))
  }

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

/// The tokens of one `claude -p` call. `cacheWrite` counts the input tokens that the call wrote to the cache.
public struct HeadlessUsage: Codable, Equatable, Sendable {
  public var input = 0
  public var output = 0
  public var cacheRead = 0
  public var cacheWrite = 0

  public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
  }

  public static func + (a: HeadlessUsage, b: HeadlessUsage) -> HeadlessUsage {
    HeadlessUsage(
      input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
      cacheWrite: a.cacheWrite + b.cacheWrite)
  }
}

/// What a `claude -p` call printed, with the tokens and the model that its envelope reports. A model that ran
/// alongside another one, as when claude hands part of the turn to a smaller model, joins the name with `+`.
public struct HeadlessReply: Sendable {
  public var output: String
  public var usage: HeadlessUsage?
  public var model: String?

  public init(output: String, usage: HeadlessUsage? = nil, model: String? = nil) {
    self.output = output
    self.usage = usage
    self.model = model
  }

  /// The `usage` and `model` keys that a `triage` or `mergeBrief` event records.
  public var eventFields: [String: JSON] {
    var fields: [String: JSON] = [:]
    if let usage { fields["usage"] = try? JSON(encoding: usage) }
    if let model { fields["model"] = .string(model) }
    return fields
  }
}
