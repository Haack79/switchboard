import AppKit
import Foundation
import SwiftUI
import SwitchboardCore
import Testing
import os

@testable import SwitchboardApp

/// sbd's `ref-details` reply for a PR, as the op writes it: sorted keys, nil fields left out, and the PR's
/// review and mergeability as the enums' raw values.
private let prReply = """
  {"author":"haacked","checks":"SUCCESS","createdAt":"2026-11-10T09:00:00Z","draft":false,"kind":"pr",\
  "labels":["enhancement"],"mergeable":"MERGEABLE","number":7,"repo":"o/r","reviewDecision":"APPROVED",\
  "source":"session","state":"open","title":"Link references","url":"https://github.com/o/r/pull/7"}
  """

private let issueReply = """
  {"draft":false,"kind":"issue","labels":[],"number":7,"read":1794377400000,"repo":"o/r","source":"fetch",\
  "state":"closed","title":"Links","updatedAt":"2026-11-13T09:00:00Z","url":"https://github.com/o/r/issues/7"}
  """

private func json(_ text: String) throws -> JSON { try JSONDecoder().decode(JSON.self, from: Data(text.utf8)) }

private func decoded(_ text: String) throws -> ReferenceDetails {
  try JSONCoding.convert(try json(text), to: ReferenceDetails.self)
}

private let ref = GitHubRef(parsing: "o/r#7")!
private let other = GitHubRef(parsing: "o/r#8")!

/// Whether `args` name `ref`, as `{ref}` or as `{repo, number}`.
private func names(_ args: [String: JSON], _ ref: GitHubRef) -> Bool {
  if let text = args["ref"]?.string { return args.count == 1 && GitHubRef(parsing: text)?.key == ref.key }
  return args.count == 2 && args["repo"]?.string?.lowercased() == ref.repo.lowercased()
    && args["number"]?.int == ref.number
}

/// A fake sbd that answers `ref-details` from a list of replies and records each call's args. While `held`, each
/// `ref-details` call waits until the test releases it. Every other op answers null at once.
private final class FakeSbd: Sendable {
  enum Reply: Sendable {
    case answer(JSON)
    case refusal(String)
  }

  private struct State: Sendable {
    var replies: [Reply] = []
    var calls: [[String: JSON]] = []
    var held = false
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let gate = DispatchSemaphore(value: 0)

  var calls: [[String: JSON]] { state.withLock { $0.calls } }

  func reply(_ replies: Reply...) { reply(contentsOf: replies) }
  func reply(contentsOf replies: [Reply]) { state.withLock { $0.replies += replies } }
  func hold() { state.withLock { $0.held = true } }

  /// Lets every held call and every later call through.
  func release() {
    state.withLock { $0.held = false }
    for _ in 0..<20 { gate.signal() }
  }

  func send(_ op: String, _ args: [String: JSON]) throws -> JSON {
    guard op == "ref-details" else { return .null }
    let (reply, held) = state.withLock { s -> (Reply?, Bool) in
      s.calls.append(args)
      return (s.replies.isEmpty ? nil : s.replies.removeFirst(), s.held)
    }
    if held { gate.wait() }
    switch reply {
    case .answer(let value)?: return value
    case .refusal(let message)?: throw APIError(message)
    case nil: throw APIError("no reply set")
    }
  }
}

@MainActor
private func model(_ sbd: FakeSbd) -> BoardModel {
  let model = offlineModel()
  model.send = { try sbd.send($0, $1) }
  return model
}

/// Waits long enough for a request that a bug would send to reach the fake sbd.
private func idle() async { try? await Task.sleep(nanoseconds: 200_000_000) }

@MainActor
@Suite struct BoardModelReferenceTests {
  @Test func aLoadSendsRefDetailsNamingTheReference() async throws {
    let sbd = FakeSbd()
    sbd.reply(.answer(try json(prReply)))
    let model = model(sbd)

    model.loadReference(ref)
    await settle { !sbd.calls.isEmpty }

    let args = try #require(sbd.calls.first)
    #expect(names(args, ref))
  }

  @Test func aKeyIsLoadingUntilSbdAnswers() async throws {
    let sbd = FakeSbd()
    sbd.reply(.answer(try json(prReply)))
    sbd.hold()
    defer { sbd.release() }
    let model = model(sbd)

    model.loadReference(ref)

    #expect(model.references.details[ref.key] == .loading)
  }

  @Test func theAnswerReplacesLoading() async throws {
    let sbd = FakeSbd()
    sbd.reply(.answer(try json(prReply)))
    sbd.hold()
    let model = model(sbd)
    model.loadReference(ref)

    sbd.release()
    await settle { model.references.details[ref.key] != .loading }

    #expect(model.references.details[ref.key] == .loaded(try decoded(prReply)))
  }

  /// Parity with the op: the app reads sbd's real reply shape, with nil fields left out.
  @Test(arguments: [prReply, issueReply])
  func theAnswerDecodesSbdsReply(_ reply: String) async throws {
    let sbd = FakeSbd()
    sbd.reply(.answer(try json(reply)))
    let model = model(sbd)

    model.loadReference(ref)
    await settle { model.references.details[ref.key] != .loading }

    #expect(model.references.details[ref.key] == .loaded(try decoded(reply)))
  }

  @Test func aPRAnswerKeepsItsReviewAndMergeability() async throws {
    let sbd = FakeSbd()
    sbd.reply(.answer(try json(prReply)))
    let model = model(sbd)

    model.loadReference(ref)
    await settle { model.references.details[ref.key] != .loading }

    guard case .loaded(let details)? = model.references.details[ref.key] else {
      Issue.record("no loaded details")
      return
    }
    #expect(details.reviewDecision == .approved)
    #expect(details.mergeable == .mergeable)
  }

  @Test func aRefusalStoresItsMessage() async {
    let sbd = FakeSbd()
    sbd.reply(.refusal("GitHub answered 502"))
    let model = model(sbd)

    model.loadReference(ref)
    await settle { model.references.details[ref.key] != .loading }

    #expect(model.references.details[ref.key] == .failed("GitHub answered 502"))
  }

  @Test func aNotFoundReplyStoresNotFound() async throws {
    let sbd = FakeSbd()
    sbd.reply(.answer(try json(#"{"notFound":true,"number":7,"repo":"o/r"}"#)))
    let model = model(sbd)

    model.loadReference(ref)
    await settle { model.references.details[ref.key] != .loading }

    #expect(model.references.details[ref.key] == .notFound)
  }

  /// The card shows the error. The window's banner is for actions the user took.
  @Test func aRefusalLeavesTheErrorBannerAlone() async {
    let sbd = FakeSbd()
    sbd.reply(.refusal("paused after a GitHub GraphQL rate limit"))
    let model = model(sbd)

    model.loadReference(ref)
    await settle { model.references.details[ref.key] != .loading }

    #expect(model.actionError == nil)
  }

  @Test func aLoadedValueStaysWhileTheNextAnswerIsInFlight() async throws {
    let sbd = FakeSbd()
    sbd.reply(.answer(try json(prReply)), .answer(try json(issueReply)))
    let model = model(sbd)
    model.loadReference(ref)
    await settle { model.references.details[ref.key] != .loading }
    try #require(model.references.details[ref.key] == .loaded(try decoded(prReply)))
    sbd.hold()
    defer { sbd.release() }

    model.loadReference(ref)
    await settle { sbd.calls.count == 2 }

    #expect(model.references.details[ref.key] == .loaded(try decoded(prReply)))
  }

  @Test func aRefreshReplacesTheLoadedValueWithTheNewAnswer() async throws {
    let sbd = FakeSbd()
    sbd.reply(.answer(try json(prReply)), .answer(try json(issueReply)))
    let newer = try decoded(issueReply)
    let model = model(sbd)
    model.loadReference(ref)
    await settle { model.references.details[ref.key] != .loading }

    model.loadReference(ref)
    await settle { model.references.details[ref.key] == .loaded(newer) }

    #expect(model.references.details[ref.key] == .loaded(newer))
  }

  @Test func oneLoadSendsOneRequest() async throws {
    let sbd = FakeSbd()
    sbd.reply(.answer(try json(prReply)))
    let model = model(sbd)

    model.loadReference(ref)
    await settle { model.references.details[ref.key] != .loading }
    await idle()

    #expect(sbd.calls.count == 1)
  }

  @Test func aSecondLoadWhileOneIsInFlightSendsNothing() async throws {
    let sbd = FakeSbd()
    sbd.reply(.answer(try json(prReply)), .answer(try json(prReply)))
    sbd.hold()
    defer { sbd.release() }
    let model = model(sbd)
    model.loadReference(ref)
    await settle { sbd.calls.count == 1 }

    model.loadReference(ref)
    await idle()

    #expect(sbd.calls.count == 1)
  }

  /// A guard that never sends again would pass the in-flight test.
  @Test func aLoadAfterTheAnswerSendsAgain() async throws {
    let sbd = FakeSbd()
    sbd.reply(.answer(try json(prReply)), .answer(try json(prReply)))
    sbd.hold()
    let model = model(sbd)
    model.loadReference(ref)
    model.loadReference(ref)
    sbd.release()
    await settle { model.references.details[ref.key] != .loading }

    model.loadReference(ref)
    await settle { sbd.calls.count == 2 }

    #expect(sbd.calls.count == 2)
  }

  @Test func aLoadAfterARefusalSendsAgain() async throws {
    let sbd = FakeSbd()
    sbd.reply(.refusal("network down"), .answer(try json(prReply)))
    let answer = try decoded(prReply)
    let model = model(sbd)
    model.loadReference(ref)
    await settle { model.references.details[ref.key] != .loading }

    model.loadReference(ref)
    await settle { model.references.details[ref.key] == .loaded(answer) }

    #expect(sbd.calls.count == 2)
  }

  @Test func aLoadForAnotherKeyWhileOneIsInFlightSendsItsOwnRequest() async throws {
    let sbd = FakeSbd()
    sbd.reply(.answer(try json(prReply)), .answer(try json(prReply)))
    sbd.hold()
    defer { sbd.release() }
    let model = model(sbd)
    model.loadReference(ref)
    await settle { sbd.calls.count == 1 }

    model.loadReference(other)
    await settle { sbd.calls.count == 2 }

    #expect(sbd.calls.count == 2)
    #expect(names(try #require(sbd.calls.last), other))
  }

  /// A bare `#7`, `o/r#7`, and the issue URL are one item. They share a key, so they share one request.
  @Test func referencesWrittenDifferentlyShareOneRequest() async throws {
    let sbd = FakeSbd()
    sbd.reply(.answer(try json(prReply)), .answer(try json(prReply)))
    sbd.hold()
    defer { sbd.release() }
    let model = model(sbd)
    model.loadReference(ref)
    await settle { sbd.calls.count == 1 }

    model.loadReference(try #require(GitHubRef(parsing: "https://github.com/O/R/issues/7")))
    await idle()

    #expect(sbd.calls.count == 1)
  }

  @Test func theStoreIsClearedPastFiveHundredKeys() async throws {
    let sbd = FakeSbd()
    let model = model(sbd)
    let refs = (1...501).map { GitHubRef(repo: "o/r", number: $0)! }
    sbd.reply(contentsOf: refs.map { _ in .refusal("not found") })

    for r in refs { model.loadReference(r) }
    await settle { sbd.calls.count == refs.count }
    await settle { !model.references.details.values.contains(.loading) }
    await idle()

    #expect(model.references.details.count <= 500)
  }
}

/// The reference card asks sbd once each time it opens. A card that asked from `body` would ask again on every
/// model or store update, because each answer publishes and runs `body` again.
@MainActor
@Suite struct ReferenceCardLoadTests {
  /// Hosts the card in a window that is never shown, and draws it once.
  private func host(_ model: BoardModel, _ ref: GitHubRef) -> NSWindow {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: ReferenceCardView(model: model, ref: ref))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
      host.cacheDisplay(in: host.bounds, to: bitmap)
    }
    return window
  }

  @Test func anOpenCardAsksOnce() async throws {
    let sbd = FakeSbd()
    sbd.reply(.answer(try json(prReply)), .answer(try json(prReply)), .answer(try json(prReply)))
    let model = model(sbd)

    let window = host(model, ref)
    await settle { model.references.details[ref.key].map { $0 != .loading } == true }
    await idle()

    #expect(sbd.calls.count == 1)
    withExtendedLifetime(window) {}
  }

  @Test func aModelUpdateWhileTheCardIsOpenAsksNothing() async throws {
    let sbd = FakeSbd()
    sbd.reply(.answer(try json(prReply)), .answer(try json(prReply)), .answer(try json(prReply)))
    let model = model(sbd)
    let window = host(model, ref)
    await settle { model.references.details[ref.key].map { $0 != .loading } == true }
    try #require(sbd.calls.count == 1)

    model.apply(.success([needsItem("a"), needsItem("b")]), followups: nil)
    await idle()

    #expect(sbd.calls.count == 1)
    withExtendedLifetime(window) {}
  }

  @Test func aSecondCardForTheSameReferenceAsksAgain() async throws {
    let sbd = FakeSbd()
    sbd.reply(.answer(try json(prReply)), .answer(try json(prReply)), .answer(try json(prReply)))
    let model = model(sbd)
    let first = host(model, ref)
    await settle { model.references.details[ref.key].map { $0 != .loading } == true }

    let second = host(model, ref)
    await settle { sbd.calls.count == 2 }

    #expect(sbd.calls.count == 2)
    withExtendedLifetime((first, second)) {}
  }
}

/// The panel measures the card when it shows it. An answer makes the card taller, and the panel must grow with it.
@MainActor
@Suite struct ReferenceCardPlacementTests {
  @Test func thePanelGrowsWhenTheAnswerComes() async throws {
    _ = NSApplication.shared
    let sbd = FakeSbd()
    // The card's own task may ask again after the first answer.
    sbd.reply(.answer(try json(prReply)), .answer(try json(prReply)))
    let model = model(sbd)
    let window = NSWindow(
      contentRect: NSRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    let anchor = NSView(frame: NSRect(x: 20, y: 250, width: 40, height: 14))
    window.contentView?.addSubview(anchor)
    let presenter = HoverCardPanel<ReferenceCardID>(clickable: true) { id in
      AnyView(ReferenceCardView(model: model, ref: id.ref))
    }
    presenter.show(ReferenceCardID(ref: ref), below: HoverAnchor(view: anchor))
    defer { presenter.hide() }
    let panel = try #require(presenter.panel)
    let loading = panel.frame.height
    try #require(loading > 0)

    model.loadReference(ref)
    await settle {
      panel.contentView?.layoutSubtreeIfNeeded()
      panel.displayIfNeeded()
      return panel.frame.height > loading
    }

    #expect(model.references.details[ref.key] == .loaded(try decoded(prReply)))
    #expect(panel.frame.height > loading)
    withExtendedLifetime(window) {}
  }
}
