import CryptoKit
import Foundation
import Testing

@testable import SwitchboardCore

private func write(_ data: Data, to path: String) throws {
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try data.write(to: URL(fileURLWithPath: path))
}

private func sha256hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private let cap = 64 << 10

/// Bytes that are not all one value, so a cut in the wrong place changes the hash.
private func bytes(_ count: Int, seed: UInt8 = 7) -> Data {
  Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

/// A temporary account with one user skill, `go`.
private struct Account {
  let root: String
  var folder: String { "\(root)/account" }
  var cwd: String { "\(root)/manager" }
  var skill: String { "\(folder)/skills/go/SKILL.md" }

  init(_ data: Data) throws {
    root = try tempFolder()
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    try write(data, to: skill)
  }

  func remove() { try? FileManager.default.removeItem(atPath: root) }

  func hash() throws -> String {
    let entries = SkillCatalog.discover(account: folder, cwd: cwd, listing: nil, machine: LocalMachine())
    let entry = try #require(entries["go"])
    return try #require(entry.hash)
  }
}

private func frontmatter(_ body: String) -> Data { Data("---\nname: go\ndescription: Go.\n---\n\(body)\n".utf8) }

/// The hash of what discovery read, and the cache key built from it.
@Suite struct SkillHashTests {
  // MARK: The rule

  /// A file hashes as its first 64 KiB followed by its size in decimal.
  @Test(arguments: [0, 10, cap, cap + 1, cap + 5_000])
  func fileHashIsTheSHA256OfTheHeadFollowedByTheSizeInDecimal(_ size: Int) {
    let data = bytes(size)
    let head = data.prefix(cap)

    let hash = SkillHash.file(head: head, size: UInt64(size))

    #expect(hash == sha256hex(head + Data(String(size).utf8)))
  }

  @Test func listingHashIsTheSHA256OfTheWordListingTheNameAndTheDescription() {
    let hash = SkillHash.listing(name: "code-review", description: "Reviews the diff.")

    #expect(hash == sha256hex(Data("listing\ncode-review\nReviews the diff.".utf8)))
  }

  @Test func hashIsLowercaseHex() {
    let hash = SkillHash.file(head: Data("x".utf8), size: 1)

    #expect(hash.count == 64)
    #expect(hash.allSatisfy { "0123456789abcdef".contains($0) })
  }

  @Test func discoveredHashFollowsTheRuleForTheFileOnDisk() throws {
    let data = frontmatter("Run the pipeline.")
    let account = try Account(data)
    defer { account.remove() }

    #expect(try account.hash() == sha256hex(data + Data(String(data.count).utf8)))
  }

  @Test func discoveredHashOfAFileLongerThanTheCapCoversItsHeadAndItsSize() throws {
    let data = frontmatter("Run it.") + bytes(cap * 2)
    let account = try Account(data)
    defer { account.remove() }

    #expect(try account.hash() == sha256hex(data.prefix(cap) + Data(String(data.count).utf8)))
  }

  // MARK: What changes the hash

  @Test func anEditInsideTheHeadChangesTheHash() throws {
    let account = try Account(frontmatter("Run the pipeline."))
    defer { account.remove() }
    let before = try account.hash()

    try write(frontmatter("Run the pipelinE."), to: account.skill)

    #expect(try account.hash() != before)
  }

  /// The first 64 KiB stay the same, so only the size can tell the two files apart.
  @Test func growthPastTheCapChangesTheHash() throws {
    let head = frontmatter("Run it.") + bytes(cap)
    let account = try Account(head + bytes(10))
    defer { account.remove() }
    let before = try account.hash()

    try write(head + bytes(20), to: account.skill)

    #expect(try account.hash() != before)
  }

  @Test func anUnchangedFileKeepsItsHash() throws {
    let account = try Account(frontmatter("Run the pipeline."))
    defer { account.remove() }

    #expect(try account.hash() == account.hash())
  }

  /// One label serves the same file in every account.
  @Test func theSameFileInTwoAccountsHasOneHash() throws {
    let data = frontmatter("Run the pipeline.")
    let first = try Account(data)
    defer { first.remove() }
    let second = try Account(data)
    defer { second.remove() }

    #expect(try first.hash() == second.hash())
  }

  @Test func listingHashChangesWithTheDescription() {
    #expect(
      SkillHash.listing(name: "code-review", description: "Reviews the diff.")
        != SkillHash.listing(name: "code-review", description: "Reviews the branch."))
  }

  @Test func listingHashChangesWithTheName() {
    #expect(
      SkillHash.listing(name: "code-review", description: "Reviews.")
        != SkillHash.listing(name: "security-review", description: "Reviews."))
  }

  // MARK: The cache key

  @Test func keyIsTheVersionTheModelAndTheHash() {
    #expect(SkillLabelCache.key(hash: "abc123", model: "haiku") == "\(SkillClassifier.version)/haiku/abc123")
  }

  @Test func keyChangesWithTheModel() {
    #expect(SkillLabelCache.key(hash: "abc123", model: "haiku") != SkillLabelCache.key(hash: "abc123", model: "sonnet"))
  }

  /// A prompt change bumps the version, so a label from the old prompt never matches a key of the new one.
  @Test func keyStartsWithTheClassifierVersion() {
    #expect(SkillLabelCache.key(hash: "abc123", model: "haiku").hasPrefix("\(SkillClassifier.version)/"))
    #expect(!SkillLabelCache.key(hash: "abc123", model: "haiku").hasPrefix("\(SkillClassifier.version + 1)/"))
  }
}
