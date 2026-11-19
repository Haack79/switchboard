import AppKit
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let liveID = "seb4ec"
private let liveName = "zsh-startup-for-switchboard"
private let hiddenID = "shk7ab"
private let hiddenName = "switchboard-hidden-by-org"

/// SwiftUI builds no accessibility tree until an assistive client asks for one.
@MainActor private let accessibilityOn: Void = {
  _ = NSApplication.shared
  // The NSAccessibility protocol has no setter for this attribute. The test sends the deprecated message by its
  // selector instead.
  _ = NSApp.perform(
    NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: true, with: "AXEnhancedUserInterface")
}()

/// Every label, title, and value under `object`, read through its accessibility children and its subviews.
@MainActor
private func strings(in object: NSObject, depth: Int = 0) -> [String] {
  guard depth < 40 else { return [] }
  var found: [String] = []
  // A key that the object does not answer would raise an exception and end the test process.
  for key in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
  where object.responds(to: NSSelectorFromString(key)) {
    switch object.value(forKey: key) {
    case let s as String where !s.isEmpty: found.append(s)
    case let s as NSAttributedString where s.length > 0: found.append(s.string)
    default: break
    }
  }
  let children =
    object.responds(to: NSSelectorFromString("accessibilityChildren"))
    ? (object.value(forKey: "accessibilityChildren") as? [Any]) ?? [] : []
  for case let child as NSObject in children {
    found += strings(in: child, depth: depth + 1)
  }
  if let view = object as? NSView {
    for sub in view.subviews { found += strings(in: sub, depth: depth + 1) }
  }
  return found
}

/// The text of the reference card that the model's panel draws for `referent`.
@MainActor
private func cardText(_ model: BoardModel, _ referent: Referent) async throws -> [String] {
  accessibilityOn
  let window = NSWindow(
    contentRect: NSRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
    defer: false)
  window.isReleasedWhenClosed = false
  let anchor = NSView(frame: NSRect(x: 20, y: 250, width: 40, height: 14))
  window.contentView?.addSubview(anchor)
  let card = try #require(model.referenceCard)
  card.pin(ReferenceCardID(referent: referent), below: HoverAnchor(view: anchor))
  defer { card.interrupt() }
  let panel = try #require(card.clickableWindow)
  let content = try #require(panel.contentView)
  var found: [String] = []
  await settle {
    content.layoutSubtreeIfNeeded()
    found = strings(in: content)
    return !found.isEmpty
  }
  withExtendedLifetime(window) {}
  return found
}

private func named(_ s: SessionSummary, _ name: String) -> SessionSummary {
  var s = s
  s.name = name
  return s
}

private func contains(_ texts: [String], _ part: String) -> Bool { texts.contains { $0.contains(part) } }

extension HoverCardContentTests {
  /// The reference card's panel draws a session card for a session referent. It reads every listed session and
  /// follow-up, whatever the org filter shows.
  @MainActor
  @Suite struct SessionReferenceCard {
    /// The control: the panel's GitHub card text is readable, so the harness reads card text at all.
    @Test func theGitHubCardsHeaderIsReadable() async throws {
      let texts = try await cardText(offlineModel(), .github(try #require(GitHubRef(parsing: "o/r#1"))))

      #expect(contains(texts, "o/r #1"), "\(texts)")
    }

    @Test func aSessionCardShowsTheSessionsName() async throws {
      let model = appliedModel([named(needsItem(liveID), liveName)])

      let texts = try await cardText(model, .session(.id(liveID)))

      #expect(contains(texts, liveName), "\(texts)")
    }

    @Test func aSessionCardShowsTheSessionsId() async throws {
      let model = appliedModel([named(needsItem(liveID), liveName)])

      let texts = try await cardText(model, .session(.id(liveID)))

      #expect(contains(texts, liveID), "\(texts)")
    }

    @Test func aSessionCardShowsTheSessionsState() async throws {
      let model = appliedModel([named(needsItem(liveID, state: .needsYou), liveName)])

      let texts = try await cardText(model, .session(.id(liveID)))

      #expect(contains(texts, AttentionState.needsYou.title), "\(texts)")
    }

    @Test func aNameLinkCardShowsTheSessionThatHasTheName() async throws {
      let model = appliedModel([named(needsItem(liveID), liveName)])

      let texts = try await cardText(model, .session(.name(liveName)))

      #expect(contains(texts, liveID), "\(texts)")
    }

    /// Risk 5: the card reads every session, not the org-filtered board.
    @Test func aSessionCardShowsASessionThatTheOrgFilterHides() async throws {
      let model = orgFilterModel(posthogOnly)
      model.apply(
        .success([
          orgSession("sph234", "PostHog/posthog"), named(orgSession(hiddenID, "haacked/switchboard"), hiddenName),
        ]), followups: nil)
      try #require(!model.board.contains { $0.id == hiddenID })
      try #require(model.allSessions.contains { $0.id == hiddenID })

      let texts = try await cardText(model, .session(.id(hiddenID)))

      #expect(contains(texts, hiddenName), "\(texts)")
      #expect(!contains(texts, "Switchboard has no session"), "\(texts)")
    }

    @Test func aSessionCardShowsAnUnstartedFollowup() async throws {
      let followup = named(unstartedFollowup("sfw2up"), "follow-up-draft")
      let model = appliedModel([], followups: [followup])

      let texts = try await cardText(model, .session(.id("sfw2up")))

      #expect(contains(texts, "follow-up-draft"), "\(texts)")
    }

    // MARK: Targets that do not resolve

    @Test func anUnknownIdShowsTheBannerText() async throws {
      let texts = try await cardText(appliedModel([needsItem(liveID)]), .session(.id("sxyz23")))

      #expect(contains(texts, "Switchboard has no session sxyz23"), "\(texts)")
    }

    @Test func anUnknownNameShowsTheBannerText() async throws {
      let texts = try await cardText(appliedModel([needsItem(liveID)]), .session(.name("fix-cache")))

      #expect(contains(texts, "Switchboard has no session named \"fix-cache\""), "\(texts)")
    }

    @Test func aNameThatTwoSessionsShareShowsTheBannerText() async throws {
      let model = appliedModel([named(needsItem("sdup2a"), "dup"), named(needsItem("sdup3b"), "dup")])

      let texts = try await cardText(model, .session(.name("dup")))

      #expect(contains(texts, "\"dup\" names 2 sessions. Use the session's id link."), "\(texts)")
    }
  }
}
