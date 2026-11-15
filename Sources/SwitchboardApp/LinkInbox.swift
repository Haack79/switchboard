import Foundation

/// Passes the URLs that reach the app to the model. A URL can arrive at a cold
/// launch before `MenuBarLabel.onAppear` attaches the model, so the inbox keeps
/// each one until then.
@MainActor
final class LinkInbox {
  static let shared = LinkInbox()

  private var held: [URL] = []
  private var handler: ((URL) -> Void)?

  func receive(_ url: URL) {
    if let handler { handler(url) } else { held.append(url) }
  }

  /// Delivers the held URLs in the order they arrived, then each later one at once.
  func attach(_ handler: @escaping (URL) -> Void) {
    self.handler = handler
    let urls = held
    held = []
    urls.forEach(handler)
  }
}
