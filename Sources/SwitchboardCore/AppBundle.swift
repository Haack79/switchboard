import Foundation

public enum AppBundle {
  public static let identifier = "com.haacked.switchboard"

  /// The Switchboard app whose Contents/MacOS holds `executable`. It follows a
  /// symlink to `executable` first. It is nil for an executable outside an app,
  /// such as one in a SwiftPM build folder, and for another app's executable.
  public static func containing(executable: URL) -> URL? {
    let macOS = executable.resolvingSymlinksInPath().deletingLastPathComponent()
    let contents = macOS.deletingLastPathComponent()
    let app = contents.deletingLastPathComponent()
    guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", app.pathExtension == "app",
      Bundle(url: app)?.bundleIdentifier == identifier
    else { return nil }
    return app
  }
}
