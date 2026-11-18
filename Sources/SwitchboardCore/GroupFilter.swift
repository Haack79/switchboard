import Foundation

/// The groups whose sessions the app shows. Its keys are group ids, so a
/// renamed group stays selected. It only decides what the app shows.
public struct GroupFilter: KeyFilter {
  /// The key of work sessions in no group. Group ids hold no parentheses, so
  /// it never matches a group.
  public static let ungroupedKey = "(ungrouped)"
  public static let allTitle = "All Groups"

  /// Group ids, plus `ungroupedKey`. An empty set shows every group. Group ids are lowercase, so the
  /// protocol's lowercasing leaves them alone.
  public private(set) var keys: Set<String>

  public init(keys: some Sequence<String> = [String]()) {
    self.keys = Set(keys.map { $0.lowercased() })
  }

  /// The group that a session belongs to, or nil for the Manager and the
  /// operator, which span every group. A group chat belongs to the group it
  /// manages. `known` holds the ids that sbd last listed, or is nil before it
  /// answers. Once it answers, a work session whose id it no longer lists
  /// counts as ungrouped, as the Board's Ungrouped lane counts it. A chat
  /// whose group it no longer lists gets nil, so it shows under every filter.
  public static func key(of s: SessionSummary, known: Set<String>?) -> String? {
    guard s.kind != .manager && s.kind != .operator else { return nil }
    guard let group = group(of: s) else { return ungroupedKey }
    if let known, !known.contains(group) { return s.kind == .chat ? nil : ungroupedKey }
    return group
  }

  /// Whether sbd's last `group-ls` answer lists the group that `s` names, or `s` names none. A group that the
  /// answer lacks may be one that sbd created after the answer, so the filter can't tell whether it selects it.
  public static func isListed(_ s: SessionSummary, known: Set<String>?) -> Bool {
    guard let known else { return false }
    return group(of: s).map(known.contains) ?? true
  }

  /// The group id that a work session or a group chat names.
  private static func group(of s: SessionSummary) -> String? {
    switch s.kind {
    case .manager, .operator: nil
    case .chat: s.chat
    case .work: s.group
    }
  }

  public func shows(_ s: SessionSummary, known: Set<String>?) -> Bool {
    guard !isAll, let key = Self.key(of: s, known: known) else { return true }
    return keys.contains(key)
  }

  /// One row per group in the order of `groups`, empty ones included, then
  /// Ungrouped when it has sessions or is selected. A selected key that names
  /// no listed group gets the key as its title.
  public func entries(_ sessions: [SessionSummary], groups: [GroupSummary], known: Set<String>?) -> [FilterEntry] {
    var rows = groups.map { FilterEntry(key: $0.id, title: $0.name) }
    var index = Dictionary(rows.enumerated().map { ($1.key, $0) }) { first, _ in first }
    var ungrouped = FilterEntry(key: Self.ungroupedKey, title: BoardRows.ungroupedTitle)
    func row(_ key: String) -> Int {
      if let i = index[key] { return i }
      index[key] = rows.count
      rows.append(FilterEntry(key: key, title: key))
      return rows.count - 1
    }
    for s in sessions {
      guard let key = Self.key(of: s, known: known) else { continue }
      if key == Self.ungroupedKey { ungrouped.add(s) } else { rows[row(key)].add(s) }
    }
    for key in keys.sorted() where key != Self.ungroupedKey { _ = row(key) }
    if ungrouped.count > 0 || keys.contains(Self.ungroupedKey) { rows.append(ungrouped) }
    return rows
  }

  /// The filter without the group ids that `known` lacks. Ungrouped stays.
  public func pruned(known: Set<String>) -> GroupFilter {
    GroupFilter(keys: keys.filter { $0 == Self.ungroupedKey || known.contains($0) })
  }
}
