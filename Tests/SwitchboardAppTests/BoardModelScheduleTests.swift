import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelScheduleTests {
  @Test func pausingAScheduleSendsPauseScheduleWithPausedTrue() async {
    let sent = await firstRequest { $0.pauseSchedule("r1", paused: true) }

    #expect(sent.op == "pause-schedule")
    #expect(sent.args == ["schedule": "r1", "paused": true])
  }

  @Test func resumingAScheduleSendsPauseScheduleWithPausedFalse() async {
    let sent = await firstRequest { $0.pauseSchedule("r1", paused: false) }

    #expect(sent.op == "pause-schedule")
    #expect(sent.args == ["schedule": "r1", "paused": false])
  }

  @Test func removingAScheduleSendsRemoveScheduleWithTheId() async {
    let sent = await firstRequest { $0.removeSchedule("r1") }

    #expect(sent.op == "remove-schedule")
    #expect(sent.args == ["schedule": "r1"])
  }

  @Test func runningAScheduleNowSendsRunScheduleWithTheId() async {
    let sent = await firstRequest { $0.runSchedule("r1") }

    #expect(sent.op == "run-schedule")
    #expect(sent.args == ["schedule": "r1"])
  }
}
