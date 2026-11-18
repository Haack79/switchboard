import Foundation
import SwitchboardCore
import Testing

/// `sb focus` resolves the reference through sbd and opens the session's link with `$SB_OPEN`. Each test points
/// `SB_OPEN` at a stub that records its arguments. sb runs from the build folder outside an app bundle, so the
/// stub gets the URL with no `-a`, except in the test that copies sb into an app.
@Suite(.blocking(timeLimit: .seconds(120))) struct FocusTests {
  /// An `open` stand-in. It writes each argument on its own line and ends each call with a `--end--` line. It
  /// prints `stderr` to standard error and exits with `status`.
  private struct FakeOpen {
    let path: String
    let log: String

    init(in sbd: Instance, status: Int = 0, stderr: String = "") throws {
      path = "\(sbd.home.path)/fake-open"
      log = "\(sbd.home.path)/fake-open.log"
      let script =
        "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >>\(shellQuote(log)); done\n"
        + "echo --end-- >>\(shellQuote(log))\n"
        + (stderr.isEmpty ? "" : "echo \(shellQuote(stderr)) >&2\n")
        + "exit \(status)\n"
      try script.write(toFile: path, atomically: true, encoding: .utf8)
      chmod(path, 0o755)
    }

    var env: [String: String] { ["SB_OPEN": path] }

    /// The argument lists of the calls so far.
    func calls() -> [[String]] {
      guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return [] }
      var calls: [[String]] = []
      var current: [String] = []
      for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line == "--end--" {
          calls.append(current)
          current = []
        } else if !line.isEmpty {
          current.append(String(line))
        }
      }
      return calls
    }
  }

  enum Ref: String, CaseIterable {
    case id, prefix, name

    func text(for s: SessionSummary) -> String {
      switch self {
      case .id: s.id
      case .prefix: String(s.id.prefix(s.id.count - 1))
      case .name: s.name
      }
    }
  }

  // MARK: Resolving the reference

  @Test(arguments: Ref.allCases)
  func focusOpensTheLinkOfTheSessionThatTheRefNames(_ ref: Ref) throws {
    let sbd = try Instance()
    let open = try FakeOpen(in: sbd)
    let s = try sbd.new(name: "flag-cache-race")

    let r = try sbd.run(["focus", ref.text(for: s)], env: open.env)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(open.calls() == [[SessionLink.url(for: s.id).absoluteString]])
  }

  /// The app parses the URL with `SessionLink.target(from:)`, so the URL that sb opens must parse back to the id.
  @Test func theURLThatFocusOpensParsesBackToTheSessionsId() throws {
    let sbd = try Instance()
    let open = try FakeOpen(in: sbd)
    let s = try sbd.new(name: "flag-cache-race")

    try sbd.sb(["focus", s.name], env: open.env)

    let opened = try #require(open.calls().first?.last)
    let url = try #require(URL(string: opened))
    #expect(SessionLink.target(from: url) == .id(s.id))
  }

  // MARK: Output

  /// The first line names the session that a prefix or name resolved to, as `sb get` prints it.
  @Test func focusPrintsTheSessionAsGetDoes() throws {
    let sbd = try Instance()
    let open = try FakeOpen(in: sbd)
    let s = try sbd.new(name: "flag-cache-race")

    let out = try sbd.sb(["focus", s.name], env: open.env)

    let get = try sbd.sb("get", s.id)
    #expect(out.split(separator: "\n").first == get.split(separator: "\n").first)
    #expect(out.hasPrefix("\(s.id)  \(s.name)"))
  }

  @Test func focusJSONPrintsTheSummaryWithTheResolvedId() throws {
    let sbd = try Instance()
    let open = try FakeOpen(in: sbd)
    let s = try sbd.new(name: "flag-cache-race")

    let out = try sbd.sb(["focus", s.name, "--json"], env: open.env)

    let summary = try #require(JSON.parse(out)?.object)
    #expect(summary["id"]?.string == s.id)
    #expect(summary["name"]?.string == s.name)
  }

  // MARK: Refusals that leave open alone

  @Test func focusOnAnUnknownRefExitsOneWithoutOpening() throws {
    let sbd = try Instance()
    let open = try FakeOpen(in: sbd)
    _ = try sbd.new(name: "flag-cache-race")

    let r = try sbd.run(["focus", "sxxxxx"], env: open.env)

    #expect(r.status == 1)
    #expect(r.stderr.contains("no session sxxxxx"), "\(r.stderr)")
    #expect(open.calls().isEmpty)
  }

  /// Every session id starts with `s`, so `s` matches both sessions.
  @Test func focusOnAnAmbiguousPrefixExitsOneWithoutOpening() throws {
    let sbd = try Instance()
    let open = try FakeOpen(in: sbd)
    _ = try sbd.new(name: "flag-cache-race")
    _ = try sbd.new(name: "old-flag-cleanup")

    let r = try sbd.run(["focus", "s"], env: open.env)

    #expect(r.status == 1)
    #expect(r.stderr.contains("matches 2 sessions"), "\(r.stderr)")
    #expect(open.calls().isEmpty)
  }

  @Test func focusOnANameThatTwoSessionsShareExitsOneWithoutOpening() throws {
    let sbd = try Instance()
    let open = try FakeOpen(in: sbd)
    _ = try sbd.new(name: "flag-cache-race")
    _ = try sbd.new(name: "flag-cache-race")

    let r = try sbd.run(["focus", "flag-cache-race"], env: open.env)

    #expect(r.status == 1)
    #expect(open.calls().isEmpty)
  }

  @Test func focusOnARemovedSessionExitsOneWithoutOpening() throws {
    let sbd = try Instance()
    let open = try FakeOpen(in: sbd)
    let s = try sbd.new(name: "flag-cache-race")
    try sbd.sb("rm", s.id)

    let r = try sbd.run(["focus", s.id], env: open.env)

    #expect(r.status == 1)
    #expect(open.calls().isEmpty)
  }

  @Test func focusWithNoRefExitsOneWithoutOpening() throws {
    let sbd = try Instance()
    let open = try FakeOpen(in: sbd)

    let r = try sbd.run(["focus"], env: open.env)

    #expect(r.status == 1)
    #expect(r.stderr.contains("focus needs a session"), "\(r.stderr)")
    #expect(open.calls().isEmpty)
  }

  @Test func focusWhileSbdIsDownExitsOneWithoutOpening() throws {
    let sbd = try Instance(startingSbd: false)
    let open = try FakeOpen(in: sbd)

    let r = try sbd.run(["focus", "seb4ec"], env: open.env)

    #expect(r.status == 1)
    #expect(open.calls().isEmpty)
  }

  // MARK: open failing

  @Test func focusExitsOneWithOpensErrorWhenOpenFails() throws {
    let sbd = try Instance()
    let open = try FakeOpen(in: sbd, status: 3, stderr: "LSOpenURLsWithRole() failed with error -10814")
    let s = try sbd.new(name: "flag-cache-race")

    let r = try sbd.run(["focus", s.id], env: open.env)

    #expect(r.status == 1)
    #expect(r.stderr.contains("can't open Switchboard:"), "\(r.stderr)")
    #expect(r.stderr.contains("LSOpenURLsWithRole() failed with error -10814"), "\(r.stderr)")
  }

  /// sb prints the session only after `open` succeeds, so a failure never looks like a focus.
  @Test func focusPrintsNoSessionWhenOpenFails() throws {
    let sbd = try Instance()
    let open = try FakeOpen(in: sbd, status: 3, stderr: "boom")
    let s = try sbd.new(name: "flag-cache-race")

    let r = try sbd.run(["focus", s.id], env: open.env)

    #expect(!r.stdout.contains(s.id))
  }

  // MARK: Inside Claude

  /// A parent session pointing the user at its child is the use case, so focus runs inside Claude.
  @Test func focusRunsInsideAClaudeSession() throws {
    let sbd = try Instance()
    let open = try FakeOpen(in: sbd)
    let parent = try sbd.new(name: "parent")
    let child = try sbd.new(name: "child")

    let r = try sbd.run(
      ["focus", child.name], env: open.env.merging(["CLAUDECODE": "1", "SB_SESSION_ID": parent.id]) { $1 })

    #expect(r.status == 0, "\(r.stderr)")
    #expect(open.calls() == [[SessionLink.url(for: child.id).absoluteString]])
  }

  // MARK: Inside the app

  /// `open -a` keeps Launch Services from picking a build/Switchboard.app copy in another checkout.
  @Test func focusFromAnSbInsideTheAppSendsTheLinkToThatApp() throws {
    let sbd = try Instance()
    let open = try FakeOpen(in: sbd)
    let s = try sbd.new(name: "flag-cache-race")
    let app = URL(fileURLWithPath: "\(sbd.home.path)/Switchboard.app")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let plist: [String: Any] = [
      "CFBundleIdentifier": AppBundle.identifier, "CFBundleExecutable": "sb", "CFBundlePackageType": "APPL",
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let sb = macOS.appendingPathComponent("sb").path
    try FileManager.default.copyItem(atPath: "\(Instance.bin)/sb", toPath: sb)

    let r = try runCommand(sb, ["focus", s.id], env: sbd.environment(open.env))

    #expect(r.status == 0, "\(r.stderr)")
    #expect(
      open.calls() == [["-a", app.resolvingSymlinksInPath().path, SessionLink.url(for: s.id).absoluteString]])
  }
}
