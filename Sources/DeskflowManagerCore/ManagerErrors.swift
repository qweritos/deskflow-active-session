import Foundation

public enum ManagerBackendError: Error, LocalizedError, Sendable {
  case invalidRequest(String)
  case accountNotFound(UInt32)
  case accountIneligible(String)
  case unsafeFileSystem(String)
  case invalidLaunchAgent(String)
  case processFailed(String)
  case operationInProgress
  case permissionDenied(String)
  case missingPayload(String)
  case invalidPayload(String)

  public var errorDescription: String? {
    switch self {
    case .invalidRequest(let message),
      .accountIneligible(let message),
      .unsafeFileSystem(let message),
      .invalidLaunchAgent(let message),
      .processFailed(let message),
      .permissionDenied(let message),
      .missingPayload(let message),
      .invalidPayload(let message):
      return message
    case .accountNotFound(let uid):
      return "No local account exists for uid \(uid)."
    case .operationInProgress:
      return "Another manager operation is already in progress."
    }
  }
}

extension String {
  var managerBounded: String {
    let limit = 512
    guard count > limit else { return self }
    return String(prefix(limit)) + "…"
  }
}
