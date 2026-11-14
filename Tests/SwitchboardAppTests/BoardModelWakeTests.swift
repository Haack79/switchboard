import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A key or a click in a stopped session's Claude terminal calls `wake`. sbd's `open` launches claude only while
/// it is stopped, so a repeat `open` is safe. The in-flight set keeps a burst of keys to one request at a time.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct BoardModelWake {
  /// `resume` would fail with "already running" on a second call while the summary still says stopped.
  @Test func wakeSendsOpenWithTheSession() async {
    let sent = await firstRequest { $0.wake("a") }

    #expect(sent.op == "open")
    #expect(sent.args == ["session": "a"])
  }

  @Test func aWakeMarksTheSessionWakingUntilSbdAnswers() async {
    let (model, release, requests) = heldModel()

    model.wake("a")
    await settle { requests.value == 1 }
    let held = model.waking
    release.signal()
    await settle { model.waking.isEmpty }

    #expect(held == ["a"])
    #expect(model.waking.isEmpty)
  }

  @Test func aSecondWakeWhileTheFirstIsInFlightSendsNothing() async {
    let (model, release, requests) = heldModel()

    model.wake("a")
    model.wake("a")
    // A second signal keeps a second request from holding its thread forever if the guard fails.
    release.signal()
    release.signal()
    await settle { model.waking.isEmpty }
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(requests.value == 1)
  }

  @Test func aBurstOfWakesSendsOneRequest() async {
    let (model, release, requests) = heldModel()

    for _ in 0..<5 { model.wake("a") }
    for _ in 0..<5 { release.signal() }
    await settle { model.waking.isEmpty }
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(requests.value == 1)
  }

  @Test func aWakeAfterTheAnswerSendsAgain() async {
    let model = offlineModel()
    let requests = Counter()
    model.send = { _, _ in
      requests.increment()
      return .null
    }
    model.wake("a")
    await settle { requests.value == 1 && model.waking.isEmpty }

    model.wake("a")
    await settle { requests.value == 2 }

    #expect(requests.value == 2)
  }

  @Test func aWakeAfterARefusedOneSendsAgain() async {
    let model = offlineModel()
    let requests = Counter()
    model.send = { _, _ in
      requests.increment()
      throw Refusal(description: "the host's sessions are not read yet")
    }
    model.wake("a")
    await settle { requests.value == 1 && model.waking.isEmpty }

    model.wake("a")
    await settle { requests.value == 2 }

    #expect(requests.value == 2)
  }

  /// A session on a host that sbd can't read wakes, and sbd's refusal shows in the error banner.
  @Test func aRefusedWakeShowsSbdsReason() async {
    let model = offlineModel()
    model.send = { _, _ in throw Refusal(description: "the host's sessions are not read yet") }

    model.wake("a")
    await settle { model.actionError != nil }

    #expect(model.actionError == "open: the host's sessions are not read yet")
  }

  @Test func wakesOfTwoSessionsEachGoOut() async {
    let (model, release, requests) = heldModel()

    model.wake("a")
    model.wake("b")
    release.signal()
    release.signal()
    await settle { model.waking.isEmpty && requests.value == 2 }

    #expect(requests.value == 2)
  }
}
