extension Event {
  /// The longest string that `slimmed` keeps whole.
  public static let slimStringLimit = 1000

  /// The event with its large payload parts left out, which the `events` request returns without `full`.
  /// A PostToolUse hook's `tool_response` holds the tool's whole output, so it becomes a string that gives its JSON
  /// size in bytes. Each longer string anywhere in the data keeps its first `slimStringLimit` characters, followed by
  /// the count of characters it drops.
  public var slimmed: Event {
    var data = self.data
    if case .object(var fields) = data, let response = fields["tool_response"] {
      let size = (try? JSONCoding.encoder.encode(response).count) ?? 0
      fields["tool_response"] = .string("(\(size) bytes left out. Pass full to read it.)")
      data = .object(fields)
    }
    var event = self
    event.data = Event.slim(data)
    return event
  }

  private static func slim(_ value: JSON) -> JSON {
    switch value {
    // A string has at least as many UTF-8 bytes as characters, so a short one skips the character count.
    case .string(let text) where text.utf8.count > slimStringLimit:
      let count = text.count
      guard count > slimStringLimit else { return value }
      return .string("\(text.prefix(slimStringLimit))… (\(count - slimStringLimit) more characters)")
    case .array(let items): return .array(items.map(slim))
    case .object(let fields): return .object(fields.mapValues(slim))
    default: return value
    }
  }
}
