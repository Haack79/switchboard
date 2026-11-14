import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
private final class Recorder {
  var urls: [URL] = []
  func record(_ url: URL) { urls.append(url) }
}

private let firstURL = SessionLink.url(for: "seb4ec")
private let secondURL = SessionLink.url(for: "s3k9ap")
private let thirdURL = SessionLink.url(for: "sgcctv")

/// A URL can reach the app at a cold launch before `MenuBarLabel.onAppear` attaches the model. `LinkInbox`
/// keeps each one until then.
@MainActor
@Suite struct LinkInboxTests {
  @Test func aURLReceivedBeforeAttachIsDeliveredOnAttach() {
    let inbox = LinkInbox()
    let recorder = Recorder()
    inbox.receive(firstURL)

    inbox.attach { recorder.record($0) }

    #expect(recorder.urls == [firstURL])
  }

  @Test func urlsReceivedBeforeAttachAreDeliveredInOrder() {
    let inbox = LinkInbox()
    let recorder = Recorder()
    inbox.receive(firstURL)
    inbox.receive(secondURL)
    inbox.receive(thirdURL)

    inbox.attach { recorder.record($0) }

    #expect(recorder.urls == [firstURL, secondURL, thirdURL])
  }

  /// The same link twice is two requests, such as `sb focus` run twice.
  @Test func theSameURLReceivedTwiceBeforeAttachIsDeliveredTwice() {
    let inbox = LinkInbox()
    let recorder = Recorder()
    inbox.receive(firstURL)
    inbox.receive(firstURL)

    inbox.attach { recorder.record($0) }

    #expect(recorder.urls == [firstURL, firstURL])
  }

  @Test func aURLReceivedAfterAttachIsDeliveredAtOnce() {
    let inbox = LinkInbox()
    let recorder = Recorder()
    inbox.attach { recorder.record($0) }

    inbox.receive(firstURL)

    #expect(recorder.urls == [firstURL])
  }

  @Test func attachWithNothingReceivedDeliversNothing() {
    let inbox = LinkInbox()
    let recorder = Recorder()

    inbox.attach { recorder.record($0) }

    #expect(recorder.urls.isEmpty)
  }

  @Test func aURLReceivedBeforeAttachIsDeliveredOnceWhenMoreArriveAfter() {
    let inbox = LinkInbox()
    let recorder = Recorder()
    inbox.receive(firstURL)
    inbox.attach { recorder.record($0) }

    inbox.receive(secondURL)

    #expect(recorder.urls == [firstURL, secondURL])
  }

  /// `onAppear` can run again, such as when the menu bar item redraws. A URL that the first attach delivered
  /// does not reach the model again.
  @Test func aSecondAttachDoesNotDeliverTheHeldURLsAgain() {
    let inbox = LinkInbox()
    let firstHandler = Recorder()
    let secondHandler = Recorder()
    inbox.receive(firstURL)
    inbox.attach { firstHandler.record($0) }

    inbox.attach { secondHandler.record($0) }

    #expect(firstHandler.urls == [firstURL])
    #expect(secondHandler.urls.isEmpty)
  }
}
