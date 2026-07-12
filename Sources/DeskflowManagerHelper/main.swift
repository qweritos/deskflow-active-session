import Darwin
import DeskflowManagerCore
import Foundation

private func run() throws -> Never {
  guard geteuid() == 0 else {
    throw ManagerBackendError.permissionDenied("Manager helper must run as root.")
  }

  let layout = try AppBundleLayout()
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard arguments.isEmpty else {
    throw ManagerBackendError.invalidRequest("Unsupported manager helper argument.")
  }
  let backend = DeskflowManagerBackend(
    supervisorPayload: layout.supervisorPayload,
    supervisorDesignatedRequirement: layout.supervisorDesignatedRequirement
  )
  let service = ManagerXPCService(backend: backend)
  let delegate = ManagerListenerDelegate(service: service)
  let listener = NSXPCListener(machServiceName: ManagerConstants.helperLabel)
  listener.setConnectionCodeSigningRequirement(layout.appDesignatedRequirement)
  listener.delegate = delegate
  listener.activate()

  withExtendedLifetime((listener, delegate, service, backend)) {
    dispatchMain()
  }
}

do {
  try run()
} catch {
  let message =
    (error as? LocalizedError)?.errorDescription
    ?? String(describing: error)
  FileHandle.standardError.write(Data((String(message.prefix(1_024)) + "\n").utf8))
  Darwin.exit(EXIT_FAILURE)
}
