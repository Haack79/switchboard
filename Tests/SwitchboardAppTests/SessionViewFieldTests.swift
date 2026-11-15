import AppKit
import Testing

@testable import SwitchboardApp

/// The terminal view hides its Message Claude field until the user asks for it. A draft with anything in it
/// always shows, so text typed in the Inbox summary or kept across a relaunch is never hidden.
@MainActor
@Suite struct SessionViewField {
  /// One kind of draft content, set alone on an empty draft.
  enum Content: CaseIterable {
    case text, image, error

    func fill(_ draft: MessageField.Draft) {
      switch self {
      case .text: draft.text = "Rebase onto main"
      case .image: draft.append(name: "shot.png", data: Data([0x89, 0x50, 0x4E, 0x47]))
      case .error: draft.error = "notes.txt isn't an image"
      }
    }
  }

  @Test func anEmptyDraftThatIsNotRevealedHidesTheField() {
    #expect(!SessionView.showsMessageField(revealed: false, draft: MessageField.Draft()))
  }

  @Test func aRevealedEmptyDraftShowsTheField() {
    #expect(SessionView.showsMessageField(revealed: true, draft: MessageField.Draft()))
  }

  @Test(arguments: Content.allCases)
  func aDraftWithAnyContentShowsTheFieldWithoutAReveal(_ content: Content) {
    let draft = MessageField.Draft()
    content.fill(draft)

    #expect(SessionView.showsMessageField(revealed: false, draft: draft))
  }

  @Test(arguments: Content.allCases)
  func aRevealedDraftWithContentShowsTheField(_ content: Content) {
    let draft = MessageField.Draft()
    content.fill(draft)

    #expect(SessionView.showsMessageField(revealed: true, draft: draft))
  }

  /// Whitespace alone is nothing to send, and Esc in the field hides it, so it doesn't keep the field showing.
  @Test func aDraftOfOnlyWhitespaceHidesTheField() {
    let draft = MessageField.Draft()
    draft.text = " \n"

    #expect(!SessionView.showsMessageField(revealed: false, draft: draft))
  }

  /// A sent draft clears its text, images, and error, so the field can hide again.
  @Test func aDraftClearedAfterASendHidesTheField() {
    let draft = MessageField.Draft()
    draft.text = "Rebase onto main"
    draft.append(name: "shot.png", data: Data([0x89]))
    draft.error = "notes.txt isn't an image"

    draft.clear(ifStill: "Rebase onto main", images: draft.images.map(\.id))

    #expect(!SessionView.showsMessageField(revealed: false, draft: draft))
  }
}
