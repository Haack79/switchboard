import Foundation
import Testing

@testable import SwitchboardCore

/// `MergeGuard.check` decides whether sbd merges the subject's PR for a `--then merge` wait. It is a
/// pure function of the facts that sbd read: the subject's verdict and facts, the allowlist, the live read of the PR,
/// `behind_by`, the base tip's rollup, the file sets of this PR and of earlier pending merges, the last merge sbd made
/// into the base, and the Operator's approval. It acts only when it can show every part of the merge property. Each
/// test below breaks one part of a passing input and sees no `act`.
///
/// The verdict kind is pinned only where the plan states it: `rearm` only when the subject is no longer Ready to
/// merge; `hold` for a live head that differs, for `behindBy > 0` (with the merge-main message), and for anything
/// unknown; `judgment` for a red base, a missing or stale approval, and a repository outside `operator.mergeRepos`.
@Suite struct MergeGuardTests {
  static let repo = "acme/widgets"
  static let head = samplePRHead
  static let baseTip = "b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"
  static let reply = "Done. /go finished, CI is green, and nothing is left for you."
  static let files: Set<String> = ["Sources/Cache.swift", "Tests/CacheTests.swift"]
  static let now: Int64 = 10

  /// The facts of a session whose turn ended with `reply` and whose PR #42 passes every Ready to merge condition,
  /// with merge details read at its head and no review threads.
  static func readyFacts(reply: String = reply) throws -> SessionFacts {
    var pr = readyPR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED", on: head)])
    pr.mergeDetails = MergeDetails(changedFiles: 2, threads: 0, threadsRead: 0, openThreads: 0)
    return try prFacts(pr, reply: reply)
  }

  /// The verdict that `Attention.evaluate` gives the session with `facts`.
  static func attention(_ facts: SessionFacts) -> Verdict {
    Attention.evaluate(session(), facts, now: now)
  }

  /// An input that passes every condition, so `check` acts. Each test changes one field.
  static func passing() throws -> MergeGuard.Input {
    let facts = try readyFacts()
    return MergeGuard.Input(
      mergeRepos: [repo],
      verdict: attention(facts),
      facts: facts,
      live: MergeGuard.LivePR(
        head: head, state: .open, draft: false, mergeable: .mergeable, base: "main", rollup: "SUCCESS"),
      behindBy: 0,
      baseTip: baseTip,
      baseRollup: "SUCCESS",
      files: files,
      earlierFiles: [],
      lastSbdMerge: nil,
      approval: MergeGuard.Approval(head: head, replyDigest: MergeGuard.replyDigest(reply)))
  }

  static func check(_ edit: (inout MergeGuard.Input) throws -> Void) throws -> MergeGuard.Verdict {
    var input = try passing()
    try edit(&input)
    return MergeGuard.check(input)
  }
}

extension MergeGuard.Verdict {
  var acts: Bool {
    if case .act = self { return true }
    return false
  }

  var holds: Bool {
    if case .hold = self { return true }
    return false
  }

  var rearms: Bool {
    if case .rearm = self { return true }
    return false
  }

  var asksForJudgment: Bool {
    if case .judgment = self { return true }
    return false
  }

  /// The message that a hold sends to the subject, or nil.
  var holdMessage: String? {
    if case .hold(_, let message) = self { return message }
    return nil
  }

  var question: String? {
    if case .judgment(let question) = self { return question }
    return nil
  }
}

// MARK: The passing input

extension MergeGuardTests {
  @Suite struct Passing {
    @Test func theSampleSessionIsReadyToMerge() throws {
      #expect(try MergeGuardTests.passing().verdict?.state == .readyToMerge)
    }

    @Test func everyConditionPassingActs() throws {
      #expect(MergeGuard.check(try MergeGuardTests.passing()).acts)
    }

    /// The allowlist matches the repository with any case, as `Dependencies.sameRepo` does.
    @Test func theAllowlistMatchesTheRepositoryWithAnyCase() throws {
      let verdict = try MergeGuardTests.check { $0.mergeRepos = [MergeGuardTests.repo.uppercased()] }

      #expect(verdict.acts, "\(verdict)")
    }

    @Test func anEarlierPendingMergeOfOtherFilesActs() throws {
      let verdict = try MergeGuardTests.check { $0.earlierFiles = [["README.md"], ["docs/plan.md"]] }

      #expect(verdict.acts, "\(verdict)")
    }
  }
}

// MARK: The allowlist and the subject

extension MergeGuardTests {
  @Suite struct Subject {
    /// Taking the repository off the list makes armed waits fall back to judgment.
    @Test(arguments: [[], ["acme/other"], ["acme"], ["widgets"]] as [[String]])
    func aRepositoryOutsideTheAllowlistAsksForJudgment(_ mergeRepos: [String]) throws {
      let verdict = try MergeGuardTests.check { $0.mergeRepos = mergeRepos }

      #expect(verdict.asksForJudgment, "\(verdict)")
    }

    /// The Operator's approval covers the reply. It never covers a repository the user did not list.
    @Test func anApprovalDoesNotOverrideTheAllowlist() throws {
      let verdict = try MergeGuardTests.check { $0.mergeRepos = [] }

      #expect(!verdict.acts, "\(verdict)")
    }

    /// Nil is a subject that was removed, or that `rm` or the removal job holds, between the trigger and the run.
    @Test func aSubjectThatIsGoneDoesNotAct() throws {
      let verdict = try MergeGuardTests.check { $0.verdict = nil }

      #expect(!verdict.acts, "\(verdict)")
    }

    @Test(arguments: AttentionState.allCases.filter { $0 != .readyToMerge })
    func aSubjectThatIsNoLongerReadyToMergeRearms(_ state: AttentionState) throws {
      let verdict = try MergeGuardTests.check { $0.verdict = Verdict(state: state, reason: "it moved on") }

      #expect(verdict.rearms, "\(verdict)")
    }

    /// The facts still say Ready to merge, but a turn started since, so the verdict says Working.
    @Test func aSubjectWhoseTurnStartedRearms() throws {
      var facts = try MergeGuardTests.readyFacts()
      facts.apply(event("UserPromptSubmit", 5, ["prompt": "one more thing"]))

      let verdict = try MergeGuardTests.check {
        $0.facts = facts
        $0.verdict = MergeGuardTests.attention(facts)
      }

      #expect(verdict.rearms, "\(verdict)")
    }

    /// Review is satisfied only through the Ready to merge verdict. A PR whose review is still required is not.
    @Test func aPRThatStillNeedsAReviewIsNotMerged() throws {
      var facts = try MergeGuardTests.readyFacts()
      facts.pr?.reviewDecision = .reviewRequired
      facts.pr?.verdicts = []

      let verdict = try MergeGuardTests.check {
        $0.facts = facts
        $0.verdict = MergeGuardTests.attention(facts)
      }

      #expect(!verdict.acts, "\(verdict)")
    }
  }
}

// MARK: How the repository merges, and the merge details

extension MergeGuardTests {
  @Suite struct MethodAndDetails {
    /// `mergeMethod` is unknown until the poller read both the `.trunk` folder and the merge queue setting.
    @Test(arguments: [(nil, false), (false, nil), (nil, nil)] as [(Bool?, Bool?)])
    func anUnknownMergeMethodHolds(_ trunkConfig: Bool?, _ mergeQueue: Bool?) throws {
      let verdict = try MergeGuardTests.check {
        $0.facts.pr?.trunkConfig = trunkConfig
        $0.facts.pr?.mergeQueue = mergeQueue
      }

      #expect(verdict.holds, "\(verdict)")
    }

    @Test func missingMergeDetailsHold() throws {
      let verdict = try MergeGuardTests.check { $0.facts.pr?.mergeDetails = nil }

      #expect(verdict.holds, "\(verdict)")
    }

    /// GitHub caps the threads one query reads, so threads past `threadsRead` are unknown.
    @Test(arguments: [(101, 100, 0), (3, 2, 0), (1, 0, 0)])
    func threadsThatWereNotAllReadHold(_ threads: Int, _ threadsRead: Int, _ open: Int) throws {
      let verdict = try MergeGuardTests.check {
        $0.facts.pr?.mergeDetails = MergeDetails(threads: threads, threadsRead: threadsRead, openThreads: open)
      }

      #expect(verdict.holds, "\(verdict)")
    }

    @Test(arguments: [1, 4])
    func anOpenReviewThreadDoesNotMerge(_ open: Int) throws {
      let verdict = try MergeGuardTests.check {
        $0.facts.pr?.mergeDetails = MergeDetails(threads: open, threadsRead: open, openThreads: open)
      }

      #expect(!verdict.acts, "\(verdict)")
      #expect(!verdict.rearms, "\(verdict)")
    }
  }
}

// MARK: The live read of the PR

extension MergeGuardTests {
  @Suite struct LiveRead {
    @Test func aLiveReadThatFailedHolds() throws {
      let verdict = try MergeGuardTests.check { $0.live = nil }

      #expect(verdict.holds, "\(verdict)")
    }

    /// A push landed after the poller's read, so the facts, the merge details, and the approval describe an older
    /// head.
    @Test func aLiveHeadThatDiffersFromThePollersHeadHolds() throws {
      let verdict = try MergeGuardTests.check { $0.live?.head = "pushed-after-the-poll" }

      #expect(verdict.holds, "\(verdict)")
    }

    /// An empty head on both sides matches, but `--match-head-commit` would then pin nothing.
    @Test func anEmptyHeadHolds() throws {
      let verdict = try MergeGuardTests.check {
        $0.facts.pr?.headSha = ""
        $0.live?.head = ""
        $0.approval = MergeGuard.Approval(head: "", replyDigest: MergeGuard.replyDigest(MergeGuardTests.reply))
      }

      #expect(verdict.holds, "\(verdict)")
    }

    /// The merge details hold only for the poller's head. A live head that moved means they were read at an
    /// older head, even when the poller's read says the details exist.
    @Test func mergeDetailsReadAtAnOlderHeadDoNotMerge() throws {
      let verdict = try MergeGuardTests.check {
        $0.live?.head = "newer"
        $0.approval = MergeGuard.Approval(head: "newer", replyDigest: MergeGuard.replyDigest(MergeGuardTests.reply))
      }

      #expect(!verdict.acts, "\(verdict)")
    }

    /// The rollup counts on the commit that GitHub merges, which is the live head, not on the poller's read.
    @Test(arguments: ["PENDING", "FAILURE", "ERROR", "EXPECTED", nil] as [String?])
    func aLiveRollupThatIsNotSuccessDoesNotMerge(_ rollup: String?) throws {
      let verdict = try MergeGuardTests.check { $0.live?.rollup = rollup }

      #expect(!verdict.acts, "\(verdict)")
    }

    @Test(arguments: [Mergeable.unknown, nil] as [Mergeable?])
    func anUnknownMergeabilityHolds(_ mergeable: Mergeable?) throws {
      let verdict = try MergeGuardTests.check { $0.live?.mergeable = mergeable }

      #expect(verdict.holds, "\(verdict)")
    }

    @Test func aConflictingPRDoesNotMerge() throws {
      let verdict = try MergeGuardTests.check { $0.live?.mergeable = .conflicting }

      #expect(!verdict.acts, "\(verdict)")
    }

    @Test func aDraftDoesNotMerge() throws {
      let verdict = try MergeGuardTests.check { $0.live?.draft = true }

      #expect(!verdict.acts, "\(verdict)")
    }

    @Test func aClosedPRDoesNotMerge() throws {
      let verdict = try MergeGuardTests.check { $0.live?.state = .closed }

      #expect(!verdict.acts, "\(verdict)")
    }

    @Test(arguments: ["release", "develop", "haacked/stack-base"])
    func aPRThatTargetsAnotherBranchThanTheDefaultDoesNotMerge(_ base: String) throws {
      let verdict = try MergeGuardTests.check { $0.live?.base = base }

      #expect(!verdict.acts, "\(verdict)")
    }

    /// The default branch is what the base must be. When the poller never read it, the base is unknown.
    @Test func aPRWhoseDefaultBranchIsUnknownDoesNotMerge() throws {
      let verdict = try MergeGuardTests.check { $0.facts.pr?.defaultBranch = nil }

      #expect(!verdict.acts, "\(verdict)")
    }
  }
}

// MARK: Base containment

extension MergeGuardTests {
  @Suite struct Behind {
    @Test func anUnknownBehindByHolds() throws {
      let verdict = try MergeGuardTests.check { $0.behindBy = nil }

      #expect(verdict.holds, "\(verdict)")
    }

    @Test func anUnknownBehindBySendsNoMessage() throws {
      let verdict = try MergeGuardTests.check { $0.behindBy = nil }

      #expect(verdict.holdMessage == nil, "\(verdict)")
    }

    @Test(arguments: [1, 37])
    func aHeadBehindTheBaseHolds(_ behind: Int) throws {
      let verdict = try MergeGuardTests.check { $0.behindBy = behind }

      #expect(verdict.holds, "\(verdict)")
    }

    @Test func aHeadBehindTheBaseTellsTheSubjectToMergeTheBase() throws {
      let verdict = try MergeGuardTests.check { $0.behindBy = 2 }

      #expect(
        verdict.holdMessage == "Merge origin/main into your branch, resolve any conflicts, run the tests, and push.",
        "\(verdict)")
    }

    /// The message names the PR's base, which the live read gives.
    @Test func theMergeBaseMessageNamesThePRsBase() throws {
      let verdict = try MergeGuardTests.check {
        $0.facts.pr?.base = "trunk"
        $0.facts.pr?.defaultBranch = "trunk"
        $0.live?.base = "trunk"
        $0.behindBy = 2
      }

      #expect(verdict.holdMessage?.hasPrefix("Merge origin/trunk into your branch") == true, "\(verdict)")
    }
  }
}

// MARK: Base CI

extension MergeGuardTests {
  @Suite struct BaseCI {
    @Test(arguments: ["FAILURE", "ERROR"])
    func aRedBaseAsksForJudgment(_ rollup: String) throws {
      let verdict = try MergeGuardTests.check { $0.baseRollup = rollup }

      #expect(verdict.asksForJudgment, "\(verdict)")
    }

    @Test func theRedBaseQuestionNamesTheBaseTip() throws {
      let verdict = try MergeGuardTests.check { $0.baseRollup = "FAILURE" }

      #expect(verdict.question?.contains(MergeGuardTests.baseTip.prefix(7)) == true, "\(verdict)")
    }

    /// sbd can't show that the base is not red without its rollup.
    @Test func aMissingBaseRollupHolds() throws {
      let verdict = try MergeGuardTests.check { $0.baseRollup = nil }

      #expect(verdict.holds, "\(verdict)")
    }

    @Test func anUnknownBaseTipDoesNotMerge() throws {
      let verdict = try MergeGuardTests.check {
        $0.baseTip = nil
        $0.baseRollup = nil
      }

      #expect(!verdict.acts, "\(verdict)")
    }

    /// The base tip is sbd's own merge, that PR shared a file with this one, and its CI still runs.
    @Test func aPendingBaseAfterSbdsOverlappingMergeHolds() throws {
      let verdict = try MergeGuardTests.check {
        $0.baseRollup = "PENDING"
        $0.lastSbdMerge = MergeGuard.SbdMerge(commit: MergeGuardTests.baseTip, files: ["Sources/Cache.swift"])
      }

      #expect(verdict.holds, "\(verdict)")
    }

    /// Without that overlap a pending base does not hold, so merges don't line up behind a long CI run.
    @Test func aPendingBaseWithNoMergeBySbdActs() throws {
      let verdict = try MergeGuardTests.check { $0.baseRollup = "PENDING" }

      #expect(verdict.acts, "\(verdict)")
    }

    @Test func aPendingBaseAfterSbdsMergeOfOtherFilesActs() throws {
      let verdict = try MergeGuardTests.check {
        $0.baseRollup = "PENDING"
        $0.lastSbdMerge = MergeGuard.SbdMerge(commit: MergeGuardTests.baseTip, files: ["README.md"])
      }

      #expect(verdict.acts, "\(verdict)")
    }

    /// sbd's merge is no longer the base tip, so the pending run belongs to someone else's commit.
    @Test func aPendingBaseWhoseTipIsNotSbdsMergeActs() throws {
      let verdict = try MergeGuardTests.check {
        $0.baseRollup = "PENDING"
        $0.lastSbdMerge = MergeGuard.SbdMerge(commit: "an-older-merge", files: ["Sources/Cache.swift"])
      }

      #expect(verdict.acts, "\(verdict)")
    }

    /// sbd can't tell whether its merge shared a file with this PR.
    @Test func aPendingBaseAfterSbdsMergeWithUnknownFilesHolds() throws {
      let verdict = try MergeGuardTests.check {
        $0.baseRollup = "PENDING"
        $0.lastSbdMerge = MergeGuard.SbdMerge(commit: MergeGuardTests.baseTip, files: nil)
      }

      #expect(verdict.holds, "\(verdict)")
    }

    @Test func aPendingBaseAfterSbdsMergeWhenThisPRsFilesAreUnknownHolds() throws {
      let verdict = try MergeGuardTests.check {
        $0.baseRollup = "PENDING"
        $0.files = nil
        $0.lastSbdMerge = MergeGuard.SbdMerge(commit: MergeGuardTests.baseTip, files: ["README.md"])
      }

      #expect(verdict.holds, "\(verdict)")
    }
  }
}

// MARK: Earlier pending merges

extension MergeGuardTests {
  @Suite struct EarlierMerges {
    @Test func anEarlierPendingMergeThatSharesAFileHolds() throws {
      let verdict = try MergeGuardTests.check { $0.earlierFiles = [["README.md"], ["Tests/CacheTests.swift"]] }

      #expect(verdict.holds, "\(verdict)")
    }

    @Test func anEarlierPendingMergeWhoseFilesAreUnknownHolds() throws {
      let verdict = try MergeGuardTests.check { $0.earlierFiles = [["README.md"], nil] }

      #expect(verdict.holds, "\(verdict)")
    }

    @Test func thisPRsUnknownFilesWithAnEarlierPendingMergeHold() throws {
      let verdict = try MergeGuardTests.check {
        $0.files = nil
        $0.earlierFiles = [["README.md"]]
      }

      #expect(verdict.holds, "\(verdict)")
    }
  }
}

// MARK: The reply gate

extension MergeGuardTests {
  @Suite struct Approval {
    @Test func noApprovalAsksForJudgment() throws {
      let verdict = try MergeGuardTests.check { $0.approval = nil }

      #expect(verdict.asksForJudgment, "\(verdict)")
    }

    /// A push after the Operator's answer: the approval covered another commit.
    @Test func anApprovalAtAnOlderHeadAsksForJudgment() throws {
      let verdict = try MergeGuardTests.check {
        $0.approval = MergeGuard.Approval(
          head: "an-older-head", replyDigest: MergeGuard.replyDigest(MergeGuardTests.reply))
      }

      #expect(verdict.asksForJudgment, "\(verdict)")
    }

    /// A new reply after the Operator's answer: the approval covered another reply.
    @Test func anApprovalOfAnotherReplyAsksForJudgment() throws {
      let facts = try MergeGuardTests.readyFacts(reply: "Done, but should I also drop the old cache table first?")

      let verdict = try MergeGuardTests.check {
        $0.facts = facts
        $0.verdict = MergeGuardTests.attention(facts)
      }

      #expect(verdict.asksForJudgment, "\(verdict)")
    }

    @Test func anApprovalWithADigestThatMatchesNoReplyAsksForJudgment() throws {
      let verdict = try MergeGuardTests.check {
        $0.approval = MergeGuard.Approval(head: MergeGuardTests.head, replyDigest: "")
      }

      #expect(verdict.asksForJudgment, "\(verdict)")
    }

    @Test func theQuestionAboutTheReplyIsNotEmpty() throws {
      let verdict = try MergeGuardTests.check { $0.approval = nil }

      #expect(verdict.question?.isEmpty == false, "\(verdict)")
    }

    @Test func theReplyDigestIsTheSameForTheSameReply() {
      #expect(MergeGuard.replyDigest(MergeGuardTests.reply) == MergeGuard.replyDigest(MergeGuardTests.reply))
    }

    @Test(arguments: [("Done.", "Done!"), ("Done.", "Done. "), ("", "x"), ("a\nb", "a b")])
    func theReplyDigestDiffersForDifferentReplies(_ a: String, _ b: String) {
      #expect(MergeGuard.replyDigest(a) != MergeGuard.replyDigest(b))
    }

    /// A session that never replied has no reply to approve, so no approval covers it by accident.
    @Test func noReplyDiffersFromAnEmptyReply() {
      #expect(MergeGuard.replyDigest(nil) != MergeGuard.replyDigest(""))
    }
  }
}

// MARK: The order of the checks

extension MergeGuardTests {
  /// The plan's order: allowlist, subject state, verdict Ready to merge, merge method known, merge details read and no
  /// open threads, live read matches, behind_by, base CI, earlier overlap, reply approval. The Operator is asked only
  /// about a head that every mechanical check passed, so a hold or a re-arm comes before a question.
  @Suite struct Order {
    @Test func aSubjectThatMovedOnRearmsBeforeTheOperatorIsAsked() throws {
      let verdict = try MergeGuardTests.check {
        $0.verdict = Verdict(state: .working, reason: "working")
        $0.approval = nil
      }

      #expect(verdict.rearms, "\(verdict)")
    }

    @Test func aHeadBehindTheBaseHoldsBeforeTheOperatorIsAsked() throws {
      let verdict = try MergeGuardTests.check {
        $0.behindBy = 3
        $0.approval = nil
      }

      #expect(verdict.holds, "\(verdict)")
    }

    @Test func aLiveHeadThatMovedHoldsBeforeTheOperatorIsAsked() throws {
      let verdict = try MergeGuardTests.check {
        $0.live?.head = "pushed"
        $0.approval = nil
      }

      #expect(verdict.holds, "\(verdict)")
    }

    /// The same-tick pair: the later merge holds behind the earlier one without a question to the Operator.
    @Test func anEarlierOverlappingMergeHoldsBeforeTheOperatorIsAsked() throws {
      let verdict = try MergeGuardTests.check {
        $0.earlierFiles = [MergeGuardTests.files]
        $0.approval = nil
      }

      #expect(verdict.holds, "\(verdict)")
    }

    @Test func missingDetailsHoldBeforeTheOperatorIsAsked() throws {
      let verdict = try MergeGuardTests.check {
        $0.facts.pr?.mergeDetails = nil
        $0.approval = nil
      }

      #expect(verdict.holds, "\(verdict)")
    }

    @Test func theAllowlistComesBeforeTheSubjectsState() throws {
      let verdict = try MergeGuardTests.check {
        $0.mergeRepos = []
        $0.verdict = Verdict(state: .working, reason: "working")
      }

      #expect(verdict.asksForJudgment, "\(verdict)")
    }
  }
}
