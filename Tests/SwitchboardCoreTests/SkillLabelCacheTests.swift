import Foundation
import Testing

@testable import SwitchboardCore

/// A temporary folder that holds skill-labels.json.
private struct Folder {
  let root: String
  var file: String { "\(root)/skill-labels.json" }

  init() throws { root = try tempFolder() }

  func remove() { try? FileManager.default.removeItem(atPath: root) }

  func write(_ text: String) throws { try text.write(toFile: file, atomically: true, encoding: .utf8) }

  func json() throws -> JSON { try #require(JSON.parse(try String(contentsOfFile: file, encoding: .utf8))) }
}

private let workKey = SkillLabelCache.key(hash: "aaa", model: "haiku")
private let safeKey = SkillLabelCache.key(hash: "bbb", model: "haiku")

private func sample() -> SkillLabelCache {
  var cache = SkillLabelCache()
  cache.labels[workKey] = SkillLabelCache.Label(
    label: .work, reason: "It runs a pipeline.", model: "haiku", t: 1_700_000_000_000)
  cache.labels[safeKey] = SkillLabelCache.Label(label: .safe, reason: "It reads notes.", model: "haiku", t: 5)
  return cache
}

/// `~/.sb/skill-labels.json` maps a cache key to `{"label", "reason", "model", "t"}`.
@Suite struct SkillLabelCacheTests {
  @Test func savedCacheLoadsBackEqual() throws {
    let folder = try Folder()
    defer { folder.remove() }
    let cache = sample()

    try cache.save(folder.file)

    #expect(SkillLabelCache.load(folder.file) == cache)
  }

  @Test func savedFileMapsEachKeyToItsLabelReasonModelAndTime() throws {
    let folder = try Folder()
    defer { folder.remove() }

    try sample().save(folder.file)

    let json = try folder.json()
    #expect(
      json[workKey]
        == ["label": "work", "reason": "It runs a pipeline.", "model": "haiku", "t": .number(1_700_000_000_000)])
    #expect(json[safeKey]?["label"] == "safe")
    #expect(json.object?.count == 2)
  }

  @Test func loadsAHandWrittenFile() throws {
    let folder = try Folder()
    defer { folder.remove() }
    try folder.write(#"{"1/haiku/abc": {"label": "work", "reason": "It ships.", "model": "haiku", "t": 42}}"#)

    let cache = SkillLabelCache.load(folder.file)

    #expect(
      cache.labels["1/haiku/abc"] == SkillLabelCache.Label(label: .work, reason: "It ships.", model: "haiku", t: 42))
  }

  @Test func missingFileLoadsEmpty() throws {
    let folder = try Folder()
    defer { folder.remove() }

    #expect(SkillLabelCache.load(folder.file).labels.isEmpty)
  }

  @Test(arguments: ["", "{not json", "[]", #""labels""#, "null", #"{"1/haiku/abc": "work"}"#])
  func corruptFileLoadsEmpty(_ text: String) throws {
    let folder = try Folder()
    defer { folder.remove() }
    try folder.write(text)

    #expect(SkillLabelCache.load(folder.file).labels.isEmpty)
  }

  /// The fail-open guard: a stored entry that is not exactly `work` must never read back as a work label.
  @Test(arguments: [#""maybe""#, #""WORK""#, "1", "null"])
  func anEntryWithALabelOtherThanWorkOrSafeNeverLoadsAsWork(_ label: String) throws {
    let folder = try Folder()
    defer { folder.remove() }
    try folder.write(#"{"1/haiku/abc": {"label": \#(label), "reason": "x", "model": "haiku", "t": 1}}"#)

    #expect(SkillLabelCache.load(folder.file).labels["1/haiku/abc"]?.label != .work)
  }

  @Test func saveReplacesTheWholeFile() throws {
    let folder = try Folder()
    defer { folder.remove() }
    try sample().save(folder.file)
    var smaller = SkillLabelCache()
    smaller.labels[safeKey] = SkillLabelCache.Label(label: .safe, reason: "It reads notes.", model: "haiku", t: 5)

    try smaller.save(folder.file)

    #expect(SkillLabelCache.load(folder.file) == smaller)
  }

  /// An atomic write puts a new file in place with a rename, so the path gets a new inode, and a reader sees the
  /// old file or the new one, never part of one.
  @Test func saveReplacesTheFileWithARename() throws {
    let folder = try Folder()
    defer { folder.remove() }
    try folder.write(#"{"old": {"label": "safe", "reason": "x", "model": "haiku", "t": 1}}"#)
    let before = try #require(try FileManager.default.attributesOfItem(atPath: folder.file)[.systemFileNumber] as? Int)

    try sample().save(folder.file)

    let after = try #require(try FileManager.default.attributesOfItem(atPath: folder.file)[.systemFileNumber] as? Int)
    #expect(after != before)
  }

  @Test func saveLeavesNoOtherFileInTheFolder() throws {
    let folder = try Folder()
    defer { folder.remove() }

    try sample().save(folder.file)
    try sample().save(folder.file)

    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.root) == ["skill-labels.json"])
  }
}
