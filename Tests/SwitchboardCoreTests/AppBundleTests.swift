import Foundation
import Testing

@testable import SwitchboardCore

/// A temp folder that holds app bundles and executables laid out as tests need them.
private final class Folder {
  let path: String

  init() throws {
    var template = Array("/tmp/sbapp.XXXXXX".utf8CString)
    guard let dir = mkdtemp(&template) else { throw APIError("mkdtemp failed") }
    path = String(cString: dir)
  }

  deinit { try? FileManager.default.removeItem(atPath: path) }

  /// Writes an empty executable file at `relative` and returns its URL.
  @discardableResult
  func executable(_ relative: String) throws -> URL {
    let url = URL(fileURLWithPath: "\(path)/\(relative)")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  /// Writes `<app>/Contents/Info.plist` with `plist` in `format`.
  func infoPlist(
    _ app: String, _ plist: [String: Any], format: PropertyListSerialization.PropertyListFormat = .xml
  ) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
    try writeInfoPlist(app, data)
  }

  func writeInfoPlist(_ app: String, _ data: Data) throws {
    let url = URL(fileURLWithPath: "\(path)/\(app)/Contents/Info.plist")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
  }

  /// A bundle at `app` whose Info.plist names `id` and whose Contents/MacOS holds sb.
  @discardableResult
  func bundle(_ app: String, id: String = switchboardID) throws -> URL {
    try infoPlist(app, ["CFBundleIdentifier": id, "CFBundleExecutable": "Switchboard"])
    return try executable("\(app)/Contents/MacOS/sb")
  }

  func url(_ relative: String) -> URL { URL(fileURLWithPath: "\(path)/\(relative)") }
}

private let switchboardID = "com.haacked.switchboard"

/// `/tmp` is a symlink to `/private/tmp`, so both sides resolve before they compare.
private func resolved(_ url: URL?) -> String? { url?.standardizedFileURL.resolvingSymlinksInPath().path }

/// `sb focus` runs `open -a` on the bundle that this returns. A wrong answer opens a stale worktree build, so each
/// refused case is a valid bundle with one thing changed.
@Suite struct AppBundleTests {
  // MARK: Bundles that hold sb

  @Test func theInstalledAppHoldsItsSb() throws {
    let folder = try Folder()
    let sb = try folder.bundle("Applications/Switchboard.app")

    let app = AppBundle.containing(executable: sb)

    #expect(resolved(app) == resolved(folder.url("Applications/Switchboard.app")))
  }

  /// `~/.local/bin/sb` is a symlink into the installed app.
  @Test func aSymlinkIntoTheAppGivesTheApp() throws {
    let folder = try Folder()
    let sb = try folder.bundle("Applications/Switchboard.app")
    let link = folder.url(".local/bin/sb")
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sb)

    let app = AppBundle.containing(executable: link)

    #expect(resolved(app) == resolved(folder.url("Applications/Switchboard.app")))
  }

  /// `bin/bundle` writes a full Info.plist into each worktree's build folder, so its sb opens its own app.
  @Test func aWorktreeBuildAppHoldsItsSb() throws {
    let folder = try Folder()
    let sb = try folder.bundle("worktree/build/Switchboard.app")

    let app = AppBundle.containing(executable: sb)

    #expect(resolved(app) == resolved(folder.url("worktree/build/Switchboard.app")))
  }

  @Test func theBundleNameDoesNotMatter() throws {
    let folder = try Folder()
    let sb = try folder.bundle("Applications/Switchboard Beta.app")

    let app = AppBundle.containing(executable: sb)

    #expect(resolved(app) == resolved(folder.url("Applications/Switchboard Beta.app")))
  }

  @Test func theExecutableNameDoesNotMatter() throws {
    let folder = try Folder()
    try folder.bundle("Applications/Switchboard.app")
    let main = try folder.executable("Applications/Switchboard.app/Contents/MacOS/Switchboard")

    let app = AppBundle.containing(executable: main)

    #expect(resolved(app) == resolved(folder.url("Applications/Switchboard.app")))
  }

  @Test func aBinaryInfoPlistIsRead() throws {
    let folder = try Folder()
    try folder.infoPlist("Applications/Switchboard.app", ["CFBundleIdentifier": switchboardID], format: .binary)
    let sb = try folder.executable("Applications/Switchboard.app/Contents/MacOS/sb")

    let app = AppBundle.containing(executable: sb)

    #expect(resolved(app) == resolved(folder.url("Applications/Switchboard.app")))
  }

  // MARK: Paths that are not an app's sb

  @Test func aSwiftPMBuildFolderHasNoApp() throws {
    let folder = try Folder()
    let sb = try folder.executable("worktree/.build/debug/sb")

    #expect(AppBundle.containing(executable: sb) == nil)
  }

  @Test(arguments: ["com.haacked.switchboard.dev", "com.example.other", "com.haacked.Switchboard", ""])
  func anAppWithAnotherBundleIdIsRefused(_ id: String) throws {
    let folder = try Folder()
    let sb = try folder.bundle("Applications/Switchboard.app", id: id)

    #expect(AppBundle.containing(executable: sb) == nil)
  }

  @Test func anAppWithNoInfoPlistIsRefused() throws {
    let folder = try Folder()
    let sb = try folder.executable("Applications/Switchboard.app/Contents/MacOS/sb")

    #expect(AppBundle.containing(executable: sb) == nil)
  }

  @Test func anInfoPlistWithNoBundleIdIsRefused() throws {
    let folder = try Folder()
    try folder.infoPlist("Applications/Switchboard.app", ["CFBundleName": "Switchboard"])
    let sb = try folder.executable("Applications/Switchboard.app/Contents/MacOS/sb")

    #expect(AppBundle.containing(executable: sb) == nil)
  }

  @Test func anInfoPlistThatIsNotAPlistIsRefused() throws {
    let folder = try Folder()
    try folder.writeInfoPlist("Applications/Switchboard.app", Data("CFBundleIdentifier=\(switchboardID)\n".utf8))
    let sb = try folder.executable("Applications/Switchboard.app/Contents/MacOS/sb")

    #expect(AppBundle.containing(executable: sb) == nil)
  }

  @Test func aBundleIdThatIsNotAStringIsRefused() throws {
    let folder = try Folder()
    try folder.infoPlist("Applications/Switchboard.app", ["CFBundleIdentifier": [switchboardID]])
    let sb = try folder.executable("Applications/Switchboard.app/Contents/MacOS/sb")

    #expect(AppBundle.containing(executable: sb) == nil)
  }

  /// Each folder has the right Info.plist at `<folder>/Contents/Info.plist`, but the folder is not an `.app`.
  @Test(arguments: ["Switchboard", "Switchboard.app.bak", "Switchboard.appx", "Switchboard.bundle"])
  func contentsMacOSOutsideAnAppIsRefused(_ name: String) throws {
    let folder = try Folder()
    let sb = try folder.bundle("Applications/\(name)")

    #expect(AppBundle.containing(executable: sb) == nil)
  }

  /// The bundle is valid, but the executable is not directly in its Contents/MacOS.
  @Test(arguments: [
    "Contents/Resources/sb",
    "Contents/MacOS/bin/sb",
    "Contents/sb",
    "sb",
    "Contents/Frameworks/Other.framework/Contents/MacOS/sb",
  ])
  func anExecutableElsewhereInAnAppIsRefused(_ relative: String) throws {
    let folder = try Folder()
    try folder.bundle("Applications/Switchboard.app")
    let sb = try folder.executable("Applications/Switchboard.app/\(relative)")

    #expect(AppBundle.containing(executable: sb) == nil)
  }

  /// A Switchboard app nested inside another app's Contents/MacOS is not the folder that holds this sb.
  @Test func anAppAboveAnotherAppsContentsIsNotUsed() throws {
    let folder = try Folder()
    try folder.bundle("Applications/Switchboard.app")
    let sb = try folder.bundle("Applications/Switchboard.app/Contents/MacOS/Other.app", id: "com.example.other")

    #expect(AppBundle.containing(executable: sb) == nil)
  }
}
