import Foundation

/// A Codex account is a CODEX_HOME folder, such as ~/.codex or
/// ~/.codex-work. Codex keeps its login, settings, and rollouts there. A
/// keyring login leaves no file in the folder, so the folder alone counts.
public struct CodexAccount: Hashable, Sendable {
  /// The normalized folder.
  public let folder: String

  public init(folder: String) { self.folder = ClaudeAccount.normalize(folder) }

  /// The folder's name without its leading dot when it is named like a Codex
  /// folder, so ~/.codex is "codex" and ~/.codex-work is "codex-work". The
  /// agent stays in the name, so a Claude and a Codex folder with the same
  /// suffix get different names. Any other folder is named by its last part.
  public var name: String {
    let last = (folder as NSString).lastPathComponent
    return Self.isNamedLikeCodex(folder) ? String(last.dropFirst()) : last
  }

  /// Sets CODEX_HOME to the folder.
  public func apply(to env: inout [String: String]) {
    env["CODEX_HOME"] = folder
  }

  /// The command that signs the account in, for the user to run. Login is
  /// interactive, so sbd never runs it.
  public var loginCommand: String { "CODEX_HOME=\(shellQuote(folder)) codex login" }

  /// Why the folder can't be a Codex account although something names it
  /// one: it holds a Claude login, or it is named like a Claude folder. Such
  /// a folder matches both kinds, so it is refused instead of guessed.
  public var clash: String? {
    let last = (folder as NSString).lastPathComponent
    if last == ".claude" || last.hasPrefix(".claude-") {
      return "\(folder) is named like a Claude folder, so it is no Codex account"
    }
    if FileManager.default.fileExists(atPath: "\(folder)/.claude.json") {
      return "\(folder) holds a Claude login (.claude.json), so it is no Codex account"
    }
    return nil
  }

  /// Whether the folder is named ~/.codex or ~/.codex-<something>. A Mac's
  /// file system usually ignores case, so ~/.Codex-x can be the folder
  /// ~/.codex-x. A guard that keeps Claude out of Codex folders passes
  /// `ignoringCase`.
  public static func isNamedLikeCodex(_ folder: String, ignoringCase: Bool = false) -> Bool {
    let name = (ClaudeAccount.normalize(folder) as NSString).lastPathComponent
    let last = ignoringCase ? name.lowercased() : name
    return last == ".codex" || (last.hasPrefix(".codex-") && last.count > ".codex-".count)
  }

  /// Each ~/.codex and ~/.codex-* folder, by name. `Account.listed` leaves out the ones with a `clash`.
  public static func discover(home: String = NSHomeDirectory()) -> [CodexAccount] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
    return names.filter { isNamedLikeCodex($0) }.sorted().compactMap { name in
      var isDir: ObjCBool = false
      let folder = "\(home)/\(name)"
      guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else { return nil }
      return CodexAccount(folder: folder)
    }
  }
}

/// Reads the plan limits that Codex writes into its rollouts, the JSONL
/// transcripts under $CODEX_HOME/sessions/YYYY/MM/DD.
public enum CodexRollout {
  /// The limits of the newest `token_count` event that carries
  /// `rate_limits`, and the time Codex wrote it in ms since the epoch.
  public struct Reading: Equatable, Sendable {
    public var limits: [UsageLimit]
    public var checked: Int64
  }

  /// What `sb usage` shows for a Codex account without a reading.
  public static let noReading = "no Codex limits seen yet; they appear after the account's next Codex turn"

  /// The newest reading in the home's newest day folder, or nil when it
  /// has none. Rollout names start with the local start time, so path order
  /// is age order. The reader walks that day's rollouts newest first and
  /// reads each from its end. A compressed `.jsonl.zst` rollout is skipped,
  /// because Codex compresses only cold files.
  public static func rateLimits(home: String) -> Reading? {
    guard let day = newestDay("\(home)/sessions") else { return nil }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: day)) ?? []
    let rollouts = names.filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }.sorted(by: >)
    for name in rollouts {
      if let reading = lastReading("\(day)/\(name)") { return reading }
    }
    return nil
  }

  /// The newest YYYY/MM/DD folder under `sessions`, by name.
  private static func newestDay(_ sessions: String) -> String? {
    var folder = sessions
    for _ in 0..<3 {
      let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
      guard let newest = names.filter({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }).max() else { return nil }
      folder += "/\(newest)"
    }
    return folder
  }

  private static func lastReading(_ path: String) -> Reading? {
    var reading: Reading?
    Transcript.eachLineFromEnd(path, on: LocalMachine()) { data in
      reading = self.reading(data)
      return reading != nil
    }
    return reading
  }

  /// The reading in one rollout line, or nil when the line is no complete
  /// `token_count` event with at least one limit window.
  static func reading(_ data: Data) -> Reading? {
    guard let line = try? JSONCoding.decoder.decode(JSON.self, from: data), line["type"]?.string == "event_msg",
      let payload = line["payload"], payload["type"]?.string == "token_count",
      let limits = payload["rate_limits"], limits.object != nil,
      let checked = line["timestamp"]?.string.flatMap(Transcript.milliseconds)
    else { return nil }
    let windows = ["primary", "secondary"].compactMap { limits[$0] }.compactMap(limit)
    return windows.isEmpty ? nil : Reading(limits: windows, checked: checked)
  }

  /// The largest percent, window, and reset that a reading takes. A larger number, which a newer Codex could
  /// write in other units, would overflow a conversion to a whole number here or where `sb usage` prints it.
  private static let maxPercent = 10_000.0
  private static let maxWindowMinutes = 366.0 * 24 * 60
  private static let maxResetSeconds = 1e11

  /// One window, or nil when a number is missing or out of range. Codex reports `resets_at` in seconds since
  /// the epoch. A reset out of range is left out and the window stays.
  private static func limit(_ window: JSON) -> UsageLimit? {
    guard let percent = window["used_percent"]?.double, percent >= 0, percent <= maxPercent,
      let minutes = window["window_minutes"]?.double, minutes > 0, minutes <= maxWindowMinutes
    else { return nil }
    let resets = window["resets_at"]?.double.flatMap { $0 > 0 && $0 < maxResetSeconds ? Int64($0) * 1000 : nil }
    let session = minutes <= 24 * 60
    return UsageLimit(
      kind: session ? "session" : "weekly_all", label: label(minutes: minutes, session: session), percent: percent,
      resetsAt: resets)
  }

  /// The window's length, such as "5-hour" or "Weekly".
  private static func label(minutes: Double, session: Bool) -> String {
    if minutes == 7 * 24 * 60 { return "Weekly" }
    let (unit, size) = session ? ("hour", 60.0) : ("day", 24 * 60.0)
    let count = minutes / size
    return count == count.rounded() ? "\(Int(count))-\(unit)" : "\(Int(minutes))-minute"
  }
}
