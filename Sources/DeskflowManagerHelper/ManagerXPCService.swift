import DeskflowManagerCore
import Foundation

private final class DataReplyBox: @unchecked Sendable {
  let reply: (Data?, String?) -> Void

  init(_ reply: @escaping (Data?, String?) -> Void) {
    self.reply = reply
  }
}

final class ManagerXPCService: NSObject, DeskflowManagerXPCProtocol, @unchecked Sendable {
  private static let maximumRequestBytes = 64 * 1_024
  private static let maximumReplyBytes = 2 * 1_024 * 1_024
  private static let maximumErrorCharacters = 8_192
  private static let maximumConsumedAuthorizations = 4_096

  private let backend: DeskflowManagerBackend
  private let queue = DispatchQueue(label: ManagerConstants.helperLabel + ".operations")
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private var consumedAuthorizations = Set<Data>()

  init(backend: DeskflowManagerBackend) {
    self.backend = backend
  }

  func version(withReply reply: @escaping (String) -> Void) {
    reply(ManagerConstants.managerVersion)
  }

  func snapshot(withReply reply: @escaping (Data?, String?) -> Void) {
    let replyBox = DataReplyBox(reply)
    queue.async { [backend, encoder, replyBox] in
      do {
        let data = try encoder.encode(backend.snapshot())
        guard data.count <= Self.maximumReplyBytes else {
          throw ManagerBackendError.processFailed("Snapshot exceeds the reply size limit.")
        }
        replyBox.reply(data, nil)
      } catch {
        replyBox.reply(nil, Self.message(for: error))
      }
    }
  }

  func perform(
    _ request: Data,
    authorization: Data,
    withReply reply: @escaping (Data?, String?) -> Void
  ) {
    let replyBox = DataReplyBox(reply)
    queue.async { [self, backend, decoder, encoder, replyBox] in
      do {
        guard request.count <= Self.maximumRequestBytes else {
          throw ManagerBackendError.invalidRequest("Operation request is oversized.")
        }
        try AuthorizationValidator.validateAdministratorRight(authorization)
        guard !consumedAuthorizations.contains(authorization) else {
          throw ManagerBackendError.permissionDenied(
            "Administrator authorization was already used. Start the operation again."
          )
        }
        guard consumedAuthorizations.count < Self.maximumConsumedAuthorizations else {
          throw ManagerBackendError.permissionDenied(
            "The helper authorization cache is full. Repair the management helper before retrying."
          )
        }
        consumedAuthorizations.insert(authorization)
        let operation = try decoder.decode(OperationRequest.self, from: request)
        let response = try backend.perform(operation)
        let data = try encoder.encode(response)
        guard data.count <= Self.maximumReplyBytes else {
          throw ManagerBackendError.processFailed("Operation reply exceeds the size limit.")
        }
        replyBox.reply(data, nil)
      } catch {
        replyBox.reply(nil, Self.message(for: error))
      }
    }
  }

  private static func message(for error: Error) -> String {
    let value =
      (error as? LocalizedError)?.errorDescription
      ?? String(describing: error)
    return String(value.prefix(maximumErrorCharacters))
  }
}

final class ManagerListenerDelegate: NSObject, NSXPCListenerDelegate {
  private let service: ManagerXPCService

  init(service: ManagerXPCService) {
    self.service = service
  }

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    connection.exportedInterface = NSXPCInterface(with: DeskflowManagerXPCProtocol.self)
    connection.exportedObject = service
    connection.activate()
    return true
  }
}
