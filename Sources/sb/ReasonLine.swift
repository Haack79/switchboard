import SwitchboardCore

extension SessionSummary {
  /// The reason line, marked when the user acknowledged it.
  var reasonLine: String { acknowledged == true ? "\(reason) (acknowledged)" : reason }
}
