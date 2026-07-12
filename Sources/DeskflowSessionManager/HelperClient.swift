import DeskflowManagerCore
import Foundation
import Security

enum ManagerClientError: LocalizedError {
  case bundledHelperMissing
  case codeSigning(String)
  case connection(String)
  case remote(String)
  case invalidReply(String)
  case incompatibleSchema(Int)
  case authorization(OSStatus)
  case timedOut
  case mutationOutcomeUnknown
  case oversizedReply

  var errorDescription: String? {
    switch self {
    case .bundledHelperMissing:
      return
        "The signed manager helper is missing from this application. Reinstall the application."
    case .codeSigning(let detail):
      return "The manager helper's code signature could not be verified: \(detail)"
    case .connection(let detail):
      return "The manager helper could not be reached: \(detail)"
    case .remote(let detail):
      return "The manager helper could not complete the request: \(detail)"
    case .invalidReply(let detail):
      return "The manager helper returned an invalid response: \(detail)"
    case .incompatibleSchema(let schema):
      return "The manager helper uses unsupported data format version \(schema). Repair the helper."
    case .authorization(let status):
      if status == errAuthorizationCanceled {
        return "Administrator authorization was canceled."
      }
      if let message = SecCopyErrorMessageString(status, nil) as String? {
        return "Administrator authorization failed: \(message) (\(status))."
      }
      return "Administrator authorization failed with status \(status)."
    case .timedOut:
      return "The manager helper did not reply before the request timed out."
    case .mutationOutcomeUnknown:
      return
        "The app did not receive a definitive reply from the manager helper. The operation may still have completed; refresh status before making another change."
    case .oversizedReply:
      return "The manager helper returned more data than the application accepts."
    }
  }
}

private final class XPCCallState<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var connection: NSXPCConnection?
  private var terminalResult: Result<Value, Error>?

  func begin(
    continuation: CheckedContinuation<Value, Error>,
    connection: NSXPCConnection?
  ) -> Bool {
    lock.lock()
    if let result = terminalResult {
      lock.unlock()
      connection?.invalidate()
      continuation.resume(with: result)
      return false
    }
    self.continuation = continuation
    self.connection = connection
    lock.unlock()
    return true
  }

  func finish(_ result: Result<Value, Error>) {
    lock.lock()
    guard terminalResult == nil else {
      lock.unlock()
      return
    }
    terminalResult = result
    let continuation = self.continuation
    let connection = self.connection
    self.continuation = nil
    self.connection = nil
    lock.unlock()

    connection?.invalidate()
    continuation?.resume(with: result)
  }
}

final class HelperClient: @unchecked Sendable {
  private static let maximumSnapshotBytes = 2 * 1_024 * 1_024
  private static let maximumOperationBytes = 1 * 1_024 * 1_024
  private static let maximumErrorCharacters = 8_192
  private let readTimeout: TimeInterval
  private let mutationTimeout: TimeInterval

  init(
    readTimeout: TimeInterval = 60,
    mutationTimeout: TimeInterval = 600
  ) {
    self.readTimeout = readTimeout
    self.mutationTimeout = mutationTimeout
  }

  func version() async throws -> String {
    try await call(timeout: readTimeout) { proxy, finish in
      proxy.version { version in
        finish(.success(String(version.prefix(256))))
      }
    }
  }

  func snapshot() async throws -> SystemSnapshot {
    let data: Data = try await call(timeout: readTimeout) { proxy, finish in
      proxy.snapshot { data, message in
        finish(Self.dataResult(data, message: message, limit: Self.maximumSnapshotBytes))
      }
    }
    let snapshot: SystemSnapshot
    do {
      snapshot = try JSONDecoder().decode(SystemSnapshot.self, from: data)
    } catch {
      throw ManagerClientError.invalidReply(error.localizedDescription)
    }
    guard snapshot.schemaVersion == ManagerConstants.schemaVersion else {
      throw ManagerClientError.incompatibleSchema(snapshot.schemaVersion)
    }
    guard snapshot.users.count <= 1_024, snapshot.portListeners.count <= 1_024 else {
      throw ManagerClientError.invalidReply("too many status records")
    }
    guard Set(snapshot.users.map { $0.account.uid }).count == snapshot.users.count else {
      throw ManagerClientError.invalidReply("duplicate user records")
    }
    return snapshot
  }

  func perform(
    operation: ManagerOperation,
    userIDs: Set<UInt32>,
    authorization: Data
  ) async throws -> OperationResponse {
    guard
      !userIDs.isEmpty,
      userIDs.count <= ManagerConstants.maximumSelectedUsers
    else {
      throw ManagerClientError.invalidReply("invalid number of selected users")
    }
    guard authorization.count == MemoryLayout<AuthorizationExternalForm>.size else {
      throw ManagerClientError.invalidReply("invalid authorization form size")
    }
    let request = OperationRequest(
      operation: operation,
      userIDs: userIDs.sorted()
    )
    let requestData = try JSONEncoder().encode(request)
    let responseData: Data
    do {
      responseData = try await call(timeout: mutationTimeout) { proxy, finish in
        proxy.perform(requestData, authorization: authorization) { data, message in
          finish(Self.dataResult(data, message: message, limit: Self.maximumOperationBytes))
        }
      }
    } catch let error as ManagerClientError {
      switch error {
      case .connection, .timedOut, .invalidReply, .incompatibleSchema, .oversizedReply:
        throw ManagerClientError.mutationOutcomeUnknown
      default:
        throw error
      }
    }
    let response: OperationResponse
    do {
      response = try JSONDecoder().decode(OperationResponse.self, from: responseData)
    } catch {
      throw ManagerClientError.mutationOutcomeUnknown
    }
    guard response.schemaVersion == ManagerConstants.schemaVersion else {
      throw ManagerClientError.mutationOutcomeUnknown
    }
    guard
      response.operation == operation,
      response.results.count <= ManagerConstants.maximumSelectedUsers
    else {
      throw ManagerClientError.mutationOutcomeUnknown
    }
    let responseIDs = response.results.map(\.uid)
    guard
      Set(responseIDs).count == responseIDs.count,
      Set(responseIDs).isSubset(of: userIDs)
    else {
      throw ManagerClientError.mutationOutcomeUnknown
    }
    return response
  }

  private func call<Value: Sendable>(
    timeout: TimeInterval,
    _ send:
      @escaping (
        DeskflowManagerXPCProtocol,
        @escaping (Result<Value, Error>) -> Void
      ) -> Void
  ) async throws -> Value {
    let state = XPCCallState<Value>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        do {
          let connection = try makeConnection()
          guard
            state.begin(
              continuation: continuation,
              connection: connection
            )
          else {
            return
          }

          let proxyObject = connection.remoteObjectProxyWithErrorHandler { error in
            state.finish(.failure(ManagerClientError.connection(error.localizedDescription)))
          }
          guard let proxy = proxyObject as? DeskflowManagerXPCProtocol else {
            state.finish(.failure(ManagerClientError.connection("invalid XPC interface")))
            return
          }

          connection.interruptionHandler = {
            state.finish(.failure(ManagerClientError.connection("connection interrupted")))
          }
          connection.invalidationHandler = {
            state.finish(.failure(ManagerClientError.connection("connection invalidated")))
          }
          connection.activate()
          send(proxy) { result in
            state.finish(result)
          }
          DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout
          ) {
            state.finish(.failure(ManagerClientError.timedOut))
          }
        } catch {
          guard
            state.begin(
              continuation: continuation,
              connection: nil
            )
          else {
            return
          }
          state.finish(.failure(error))
        }
      }
    } onCancel: {
      state.finish(.failure(CancellationError()))
    }
  }

  private func makeConnection() throws -> NSXPCConnection {
    let requirement = try helperDesignatedRequirement()
    let connection = NSXPCConnection(
      machServiceName: ManagerConstants.helperLabel,
      options: .privileged
    )
    connection.remoteObjectInterface = NSXPCInterface(
      with: DeskflowManagerXPCProtocol.self
    )
    connection.setCodeSigningRequirement(requirement)
    return connection
  }

  private func helperDesignatedRequirement() throws -> String {
    guard let helperURL = bundledHelperURL() else {
      throw ManagerClientError.bundledHelperMissing
    }

    var staticCode: SecStaticCode?
    var status = SecStaticCodeCreateWithPath(helperURL as CFURL, [], &staticCode)
    guard status == errSecSuccess, let staticCode else {
      throw ManagerClientError.codeSigning("SecStaticCodeCreateWithPath returned \(status)")
    }

    status = SecStaticCodeCheckValidity(
      staticCode,
      SecCSFlags(rawValue: kSecCSStrictValidate),
      nil
    )
    guard status == errSecSuccess else {
      throw ManagerClientError.codeSigning("signature validation returned \(status)")
    }

    var requirement: SecRequirement?
    status = SecCodeCopyDesignatedRequirement(staticCode, [], &requirement)
    guard status == errSecSuccess, let requirement else {
      throw ManagerClientError.codeSigning("no designated requirement (\(status))")
    }

    var requirementText: CFString?
    status = SecRequirementCopyString(requirement, [], &requirementText)
    guard status == errSecSuccess, let requirementText else {
      throw ManagerClientError.codeSigning("could not serialize designated requirement (\(status))")
    }
    return requirementText as String
  }

  private func bundledHelperURL() -> URL? {
    var candidates: [URL] = []
    if let auxiliary = Bundle.main.url(
      forAuxiliaryExecutable: ManagerConstants.helperExecutableName
    ) {
      candidates.append(auxiliary)
    }
    candidates.append(
      Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS", isDirectory: true)
        .appendingPathComponent(ManagerConstants.helperExecutableName)
    )
    if let executable = Bundle.main.executableURL {
      candidates.append(
        executable.deletingLastPathComponent()
          .appendingPathComponent(ManagerConstants.helperExecutableName)
      )
    }
    return candidates.first {
      FileManager.default.isExecutableFile(atPath: $0.path)
    }
  }

  private static func dataResult(
    _ data: Data?,
    message: String?,
    limit: Int
  ) -> Result<Data, Error> {
    if let message, !message.isEmpty {
      return .failure(
        ManagerClientError.remote(
          String(message.prefix(maximumErrorCharacters))
        )
      )
    }
    guard let data else {
      return .failure(ManagerClientError.invalidReply("missing response data"))
    }
    guard data.count <= limit else {
      return .failure(ManagerClientError.oversizedReply)
    }
    return .success(data)
  }
}

enum AuthorizationProvider {
  static func externalForm() throws -> Data {
    var authorization: AuthorizationRef?
    var status = AuthorizationCreate(nil, nil, [], &authorization)
    guard status == errAuthorizationSuccess, let authorization else {
      throw ManagerClientError.authorization(status)
    }
    defer { AuthorizationFree(authorization, []) }

    status = kAuthorizationRightExecute.withCString { rightName in
      var item = AuthorizationItem(
        name: rightName,
        valueLength: 0,
        value: nil,
        flags: 0
      )
      return withUnsafeMutablePointer(to: &item) { itemPointer in
        var rights = AuthorizationRights(count: 1, items: itemPointer)
        return AuthorizationCopyRights(
          authorization,
          &rights,
          nil,
          [.interactionAllowed, .extendRights, .preAuthorize],
          nil
        )
      }
    }
    guard status == errAuthorizationSuccess else {
      throw ManagerClientError.authorization(status)
    }

    var externalForm = AuthorizationExternalForm()
    status = AuthorizationMakeExternalForm(authorization, &externalForm)
    guard status == errAuthorizationSuccess else {
      throw ManagerClientError.authorization(status)
    }
    return withUnsafeBytes(of: &externalForm) { Data($0) }
  }
}
