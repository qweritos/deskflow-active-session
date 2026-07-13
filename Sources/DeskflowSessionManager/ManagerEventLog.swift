import Foundation

enum ManagerLogLevel: String, Sendable {
  case debug
  case info
  case warning
  case error
}

struct ManagerLogEntry: Identifiable, Sendable {
  let id: UInt64
  let timestamp: Date
  let level: ManagerLogLevel
  let message: String

  var exportLine: String {
    "\(timestamp.ISO8601Format(.init(includingFractionalSeconds: true))) [\(level.rawValue.uppercased())] \(message)"
  }
}
