import Foundation
import Testing

@testable import SwitchboardCore

// Every call into `ReferenceCache` goes through `store`, `answer`, and `count` below, so a change to the cache's API
// changes only these helpers.

private func store(_ cache: inout ReferenceCache, _ key: String, _ answer: ReferenceCache.Answer, at now: Int64) {
  cache.store(answer, for: key, now: now)
}

private func answer(_ cache: ReferenceCache, _ key: String, at now: Int64) -> ReferenceCache.Answer? {
  cache.fresh(key, now: now)
}

private func count(_ cache: ReferenceCache) -> Int { cache.count }

private let t0: Int64 = 1_794_000_000_000
private let key = "acme/widgets#7"

private let second: Int64 = 1000
private let minute: Int64 = 60 * second
private let hour: Int64 = 60 * minute

/// Details from a session's PR or a cached issue. The initializers don't throw, so a fixture can't stop the
/// test process.
private func details(kind: String, state: String, draft: Bool = false) -> ReferenceDetails {
  guard kind == "pr" else {
    return ReferenceDetails(
      issue: InboxIssue(
        repo: "acme/widgets", number: 7, title: "Totals round twice", url: "https://github.com/acme/widgets/issues/7",
        state: state == "open" ? .open : .closed, createdAt: "2026-11-01T10:00:00Z",
        updatedAt: "2026-11-10T10:00:00Z"))
  }
  return ReferenceDetails(
    pr: PullRequest(
      id: "PR_7", number: 7, url: "https://github.com/acme/widgets/pull/7", repo: "acme/widgets",
      title: "Totals round twice", state: PRState(rawValue: state.uppercased()) ?? .open, draft: draft))
}

struct TTLCase: CustomTestStringConvertible, Sendable {
  var name: String
  var answer: ReferenceCache.Answer
  var ttl: Int64
  var testDescription: String { name }
}

/// The TTLs: 60 s for an open item, 10 min for a merged or closed item, 10 min for
/// "not found", and 30 s for any other error.
private let ttlCases = [
  TTLCase(name: "open issue", answer: .found(details(kind: "issue", state: "open")), ttl: 60 * second),
  TTLCase(name: "open PR", answer: .found(details(kind: "pr", state: "open")), ttl: 60 * second),
  TTLCase(name: "draft PR", answer: .found(details(kind: "pr", state: "open", draft: true)), ttl: 60 * second),
  TTLCase(name: "merged PR", answer: .found(details(kind: "pr", state: "merged")), ttl: 10 * minute),
  TTLCase(name: "closed PR", answer: .found(details(kind: "pr", state: "closed")), ttl: 10 * minute),
  TTLCase(name: "closed issue", answer: .found(details(kind: "issue", state: "closed")), ttl: 10 * minute),
  TTLCase(name: "not found", answer: .notFound, ttl: 10 * minute),
  TTLCase(name: "network error", answer: .failed("GitHub answered 502"), ttl: 30 * second),
  TTLCase(
    name: "rate-limit pause", answer: .failed("paused after a GitHub GraphQL rate limit"), ttl: 30 * second),
  TTLCase(name: "gh not logged in", answer: .failed("gh auth token failed: not logged in"), ttl: 30 * second),
]

@Suite struct ReferenceCacheTests {

  // MARK: TTL

  @Test(arguments: ttlCases)
  func anAnswerIsFreshOneMillisecondBeforeItsTTL(_ c: TTLCase) {
    var cache = ReferenceCache()
    store(&cache, key, c.answer, at: t0)

    #expect(answer(cache, key, at: t0 + c.ttl - 1) == c.answer)
  }

  @Test(arguments: ttlCases)
  func anAnswerIsStaleAtItsTTL(_ c: TTLCase) {
    var cache = ReferenceCache()
    store(&cache, key, c.answer, at: t0)

    #expect(answer(cache, key, at: t0 + c.ttl) == nil)
  }

  @Test func anAnswerIsFreshWhenItIsStored() {
    var cache = ReferenceCache()
    store(&cache, key, .notFound, at: t0)

    #expect(answer(cache, key, at: t0) == .notFound)
  }

  @Test func aKeyThatWasNeverStoredHasNoAnswer() {
    let cache = ReferenceCache()

    #expect(answer(cache, key, at: t0) == nil)
  }

  @Test func aNewAnswerReplacesTheOldOneAndRestartsItsTTL() {
    var cache = ReferenceCache()
    store(&cache, key, .failed("GitHub answered 502"), at: t0)
    let found = ReferenceCache.Answer.found(details(kind: "issue", state: "open"))

    store(&cache, key, found, at: t0 + 20 * second)

    #expect(answer(cache, key, at: t0 + 20 * second + 60 * second - 1) == found)
  }

  @Test func eachKeyKeepsItsOwnAnswer() {
    var cache = ReferenceCache()
    let found = ReferenceCache.Answer.found(details(kind: "issue", state: "open"))
    store(&cache, key, found, at: t0)

    store(&cache, "acme/widgets#8", .notFound, at: t0)

    #expect(answer(cache, key, at: t0) == found)
    #expect(answer(cache, "acme/widgets#8", at: t0) == .notFound)
  }

  // MARK: Size

  @Test func theCacheHoldsAtMost500Entries() {
    var cache = ReferenceCache()

    for i in 0...500 { store(&cache, "acme/widgets#\(i + 1)", .notFound, at: t0 + Int64(i)) }

    #expect(count(cache) == 500)
  }

  @Test func the501stEntryDropsTheOldest() {
    var cache = ReferenceCache()

    for i in 0...500 { store(&cache, "acme/widgets#\(i + 1)", .notFound, at: t0 + Int64(i)) }

    #expect(answer(cache, "acme/widgets#1", at: t0 + 501) == nil)
    #expect(answer(cache, "acme/widgets#2", at: t0 + 501) == .notFound)
    #expect(answer(cache, "acme/widgets#501", at: t0 + 501) == .notFound)
  }

  /// "Oldest" means stored longest ago. Storing a key again makes it the newest.
  @Test func storingAKeyAgainMakesItTheNewest() {
    var cache = ReferenceCache()
    for i in 0..<500 { store(&cache, "acme/widgets#\(i + 1)", .notFound, at: t0 + Int64(i)) }
    store(&cache, "acme/widgets#1", .notFound, at: t0 + 500)

    store(&cache, "acme/widgets#501", .notFound, at: t0 + 501)

    #expect(answer(cache, "acme/widgets#1", at: t0 + 501) == .notFound)
    #expect(answer(cache, "acme/widgets#2", at: t0 + 501) == nil)
  }

  @Test func storingAKeyAgainAddsNoEntry() {
    var cache = ReferenceCache()
    store(&cache, key, .notFound, at: t0)

    store(&cache, key, .failed("GitHub answered 502"), at: t0 + 1)

    #expect(count(cache) == 1)
  }

  // MARK: Age

  @Test func aStoreDropsEntriesOlderThanAnHour() {
    var cache = ReferenceCache()
    store(&cache, key, .notFound, at: t0)

    store(&cache, "acme/widgets#8", .notFound, at: t0 + hour + 1)

    #expect(count(cache) == 1)
  }

  @Test func aStoreKeepsStaleEntriesYoungerThanAnHour() {
    var cache = ReferenceCache()
    store(&cache, key, .notFound, at: t0)

    store(&cache, "acme/widgets#8", .notFound, at: t0 + hour - 1)

    #expect(count(cache) == 2)
  }
}
