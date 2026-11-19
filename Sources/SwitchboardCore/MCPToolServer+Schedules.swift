import Foundation

extension MCPToolServer {
  /// Sends one of the schedule requests. A scoped server adds its group and
  /// its caller, and sbd then acts only on the group's sessions and on the
  /// caller. An unscoped server sends neither, because sbd refuses a `group`
  /// that is not a group's id.
  func scheduleCall(_ op: String, _ request: [String: JSON], _ scoped: Scoped?) throws -> JSON {
    var request = request
    if let scoped {
      request["group"] = .string(scoped.group.id)
      if let caller { request["caller"] = .string(caller) }
    }
    return try client.call(op, request)
  }
}
