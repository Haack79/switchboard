import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A group lane shows Pause All when a group pause would pause a member, and Resume All when a group resume would
/// resume one. The buttons follow sbd's group fan-out: a pause acts on each work session that has started, isn't
/// marked done, and isn't paused. A resume acts on each paused work session, including one marked done.
@Suite struct GroupPauseTests {
  static let paused = Pause(by: .you, since: 0)

  /// A started work session in group g1.
  static func member(_ id: String) -> SessionSummary {
    var s = needsItem(id, state: .working)
    s.group = "g1"
    return s
  }

  static func pausedMember(_ id: String) -> SessionSummary {
    var s = member(id)
    s.pause = paused
    return s
  }

  static func markedDone(_ id: String) -> SessionSummary {
    var s = member(id)
    s.state = .done
    s.markedDone = true
    return s
  }

  static func notStarted(_ id: String) -> SessionSummary {
    var s = unstartedFollowup(id)
    s.group = "g1"
    return s
  }

  // MARK: The lane's members

  @Test func aGroupWithNoMembersOffersNeitherButton() {
    let actions = GroupPause.actions([])

    #expect(!actions.pause)
    #expect(!actions.resume)
  }

  @Test func aGroupWhoseMembersCanAllBePausedOffersOnlyPauseAll() {
    let actions = GroupPause.actions([Self.member("s1"), Self.member("s2")])

    #expect(actions.pause)
    #expect(!actions.resume)
  }

  @Test func aGroupWhoseMembersAreAllPausedOffersOnlyResumeAll() {
    let actions = GroupPause.actions([Self.pausedMember("s1"), Self.pausedMember("s2")])

    #expect(!actions.pause)
    #expect(actions.resume)
  }

  @Test func aGroupWithAPausedMemberAndOneThatCanBePausedOffersBoth() {
    let actions = GroupPause.actions([Self.pausedMember("s1"), Self.member("s2")])

    #expect(actions.pause)
    #expect(actions.resume)
  }

  @Test func aGroupOfOnlyDoneAndNotStartedMembersOffersNeitherButton() {
    let actions = GroupPause.actions([Self.markedDone("s1"), Self.notStarted("f1")])

    #expect(!actions.pause)
    #expect(!actions.resume)
  }

  // MARK: Agreement with sbd's group fan-out

  /// One member of each shape that sbd's `pauseGroup` and group `resume` treat differently, with what each does
  /// to it.
  enum Shape: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case started
    case paused
    case markedDone
    case markedDoneAndPaused
    /// A session in Done because its PR merged, which nobody marked done. sbd pauses it.
    case doneByAMergedPR
    case followupNotStarted
    /// A follow-up that has started has a folder. sbd pauses it like any other work session.
    case startedFollowup
    case docketRow
    case chat
    case pausedChat
    case manager
    case pausedManager

    var testDescription: String { rawValue }

    var session: SessionSummary {
      switch self {
      case .started: return GroupPauseTests.member("s1")
      case .paused: return GroupPauseTests.pausedMember("s1")
      case .markedDone: return GroupPauseTests.markedDone("s1")
      case .markedDoneAndPaused:
        var s = GroupPauseTests.markedDone("s1")
        s.pause = GroupPauseTests.paused
        return s
      case .doneByAMergedPR:
        var s = GroupPauseTests.member("s1")
        s.state = .done
        s.markedDone = false
        return s
      case .followupNotStarted: return GroupPauseTests.notStarted("f1")
      case .startedFollowup:
        var s = GroupPauseTests.member("f1")
        s.followup = Followup(prompt: "p")
        return s
      case .docketRow:
        var s = docketSession("d1")
        s.group = "g1"
        return s
      case .chat, .pausedChat:
        var s = chatItem("c1", group: "g1", state: .working)
        s.group = "g1"
        if self == .pausedChat { s.pause = GroupPauseTests.paused }
        return s
      case .manager, .pausedManager:
        var s = needsItem("m1", manager: true, state: .working)
        s.group = "g1"
        if self == .pausedManager { s.pause = GroupPauseTests.paused }
        return s
      }
    }

    /// True when sbd's group pause pauses this member.
    var sbdPauses: Bool { [.started, .doneByAMergedPR, .startedFollowup].contains(self) }

    /// True when sbd's group resume resumes this member.
    var sbdResumes: Bool { [.paused, .markedDoneAndPaused].contains(self) }
  }

  @Test(arguments: Shape.allCases)
  func pauseAllShowsOnlyWhenSbdWouldPauseTheMember(_ shape: Shape) {
    let actions = GroupPause.actions([shape.session])

    #expect(actions.pause == shape.sbdPauses)
  }

  @Test(arguments: Shape.allCases)
  func resumeAllShowsOnlyWhenSbdWouldResumeTheMember(_ shape: Shape) {
    let actions = GroupPause.actions([shape.session])

    #expect(actions.resume == shape.sbdResumes)
  }

  /// A member that sbd acts on still shows its button among members that sbd skips.
  @Test(arguments: Shape.allCases)
  func oneMemberThatSbdActsOnShowsItsButtonAmongSkippedMembers(_ shape: Shape) {
    let skipped = Shape.allCases.filter { !$0.sbdPauses && !$0.sbdResumes }.map(\.session)

    let actions = GroupPause.actions(skipped + [shape.session])

    #expect(actions.pause == shape.sbdPauses)
    #expect(actions.resume == shape.sbdResumes)
  }
}
