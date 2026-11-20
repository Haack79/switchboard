import SwitchboardCore
import Testing

@testable import SwitchboardApp

private func user(_ text: String, t: Int64, sent: Int64? = nil) -> ChatMessage {
  ChatMessage(role: .user, text: text, t: t, sent: sent)
}

private func assistant(_ text: String = "Done.", t: Int64) -> ChatMessage {
  ChatMessage(role: .assistant, text: text, t: t)
}

/// A loop's prompt sent three times, with a reply after each, as sbd answers a `chat-log` read with `sent`.
private func repeatedRuns(marking index: Int?, sent: Int64) -> [ChatMessage] {
  let plain = [
    user("Check the queue", t: 1), assistant(t: 2), user("Check the queue", t: 3), assistant(t: 4),
    user("Check the queue", t: 5), assistant(t: 6),
  ]
  guard let index else { return plain }
  var marked = plain
  marked[index].sent = sent
  return marked
}

@Suite struct ChatJumpTests {
  // MARK: Reading an answer

  @Test(arguments: [0, 2, 4])
  func readingFindsTheMarkedRow(_ index: Int) {
    let answer = repeatedRuns(marking: index, sent: 7)

    let read = ChatJump.reading(answer, sent: 7)

    #expect(read.found == .row(index))
  }

  @Test(arguments: [0, 2, 4])
  func readingReturnsTheLogWithoutTheMarker(_ index: Int) {
    let answer = repeatedRuns(marking: index, sent: 7)

    let read = ChatJump.reading(answer, sent: 7)

    #expect(read.log == repeatedRuns(marking: nil, sent: 7))
  }

  @Test func readingFindsNothingWhenNoMessageIsMarked() {
    let answer = repeatedRuns(marking: nil, sent: 7)

    let read = ChatJump.reading(answer, sent: 7)

    #expect(read.found == .missing)
  }

  @Test func readingFindsNothingWhenAnotherSentIsMarked() {
    let answer = repeatedRuns(marking: 2, sent: 8)

    let read = ChatJump.reading(answer, sent: 7)

    #expect(read.found == .missing)
  }

  /// A marker for another run must not reach the stored log either, or the log compares unequal to a plain read.
  @Test func readingStripsAMarkerForAnotherSent() {
    let answer = repeatedRuns(marking: 2, sent: 8)

    let read = ChatJump.reading(answer, sent: 7)

    #expect(read.log.allSatisfy { $0.sent == nil })
  }

  @Test func readingAnEmptyAnswerFindsNothing() {
    let read = ChatJump.reading([], sent: 7)

    #expect(read.log.isEmpty)
    #expect(read.found == .missing)
  }

  @Test func readingKeepsTheMessagesOrderAndContent() {
    let answer = [user("a", t: 1), assistant("b", t: 2), user("c", t: 3, sent: 7)]

    let read = ChatJump.reading(answer, sent: 7)

    #expect(read.log.map(\.text) == ["a", "b", "c"])
    #expect(read.log.map(\.t) == [1, 2, 3])
    #expect(read.log.map(\.role) == [.user, .assistant, .user])
  }

  // MARK: The scroll rule

  @Test func aJumpWithARowScrollsToThatRow() {
    let jump = ChatJump(session: "m", sent: 7, found: .row(4))

    #expect(jump.row == 4)
  }

  @Test func aJumpWithARowDoesNotFollowTheBottom() {
    let jump = ChatJump(session: "m", sent: 7, found: .row(4))

    #expect(!ChatJump.followsBottom(jump))
  }

  @Test func aJumpWhoseAnswerHasNotArrivedDoesNotFollowTheBottom() {
    let jump = ChatJump(session: "m", sent: 7)

    #expect(!ChatJump.followsBottom(jump))
  }

  @Test func aJumpWhoseAnswerHasNotArrivedHasNoRow() {
    let jump = ChatJump(session: "m", sent: 7)

    #expect(jump.row == nil)
  }

  @Test func noJumpFollowsTheBottom() {
    #expect(ChatJump.followsBottom(nil))
  }

  @Test func aMissingPromptFollowsTheBottom() {
    let jump = ChatJump(session: "m", sent: 7, found: .missing)

    #expect(ChatJump.followsBottom(jump))
  }

  @Test func aMissingPromptHasNoRow() {
    let jump = ChatJump(session: "m", sent: 7, found: .missing)

    #expect(jump.row == nil)
  }
}
