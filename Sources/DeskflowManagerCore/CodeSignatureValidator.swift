import Darwin
import Foundation
import Security

internal enum CodeSignatureValidator {
  static func validateSupervisor(
    at url: URL,
    designatedRequirement: String? = nil
  ) throws {
    let identifier = try signingIdentifier(
      at: url,
      designatedRequirement: designatedRequirement
    )
    guard identifier == ManagerConstants.supervisorIdentifier else {
      throw ManagerBackendError.invalidPayload("Supervisor signing identifier is unexpected.")
    }
  }

  static func validateExistingSupervisor(at url: URL) throws {
    let identifier = try signingIdentifier(at: url, designatedRequirement: nil)
    guard
      identifier == ManagerConstants.supervisorIdentifier
        || identifier.hasPrefix("deskflow-session-supervisor-")
    else {
      throw ManagerBackendError.invalidPayload(
        "Existing supervisor has an unexpected signing identifier."
      )
    }
  }

  private static func signingIdentifier(
    at url: URL,
    designatedRequirement: String?
  ) throws -> String {
    var metadata = stat()
    guard Darwin.lstat(url.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size > 0,
      metadata.st_size <= 64 * 1_024 * 1_024
    else {
      throw ManagerBackendError.invalidPayload(
        "Supervisor payload is missing, unsafe, or oversized.")
    }

    var staticCode: SecStaticCode?
    var status = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
    guard status == errSecSuccess, let staticCode else {
      throw ManagerBackendError.invalidPayload("Could not inspect the supervisor code signature.")
    }
    var requirement: SecRequirement?
    if let designatedRequirement {
      status = SecRequirementCreateWithString(
        designatedRequirement as CFString,
        [],
        &requirement
      )
      guard status == errSecSuccess, requirement != nil else {
        throw ManagerBackendError.invalidPayload(
          "The trusted supervisor code requirement is invalid."
        )
      }
    }
    status = SecStaticCodeCheckValidity(staticCode, [], requirement)
    guard status == errSecSuccess else {
      throw ManagerBackendError.invalidPayload("Supervisor code signature is invalid (\(status)).")
    }

    var information: CFDictionary?
    status = SecCodeCopySigningInformation(
      staticCode,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &information
    )
    let dictionary = information as? [String: Any]
    let identifier = dictionary?[kSecCodeInfoIdentifier as String] as? String
    guard status == errSecSuccess, let identifier, !identifier.isEmpty else {
      throw ManagerBackendError.invalidPayload("Supervisor signing identifier is unexpected.")
    }
    return identifier
  }
}

internal final class RootOperationLock {
  private let descriptor: Int32

  init() throws {
    guard geteuid() == 0 else {
      throw ManagerBackendError.permissionDenied("Manager mutations require root privileges.")
    }
    let path = "/var/run/deskflow-active-session-manager.lock"
    let descriptor = Darwin.open(
      path,
      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      throw ManagerBackendError.permissionDenied("Could not open the manager operation lock.")
    }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == 0,
      metadata.st_nlink == 1,
      Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
    else {
      Darwin.close(descriptor)
      throw ManagerBackendError.permissionDenied("Manager operation lock is unsafe.")
    }
    do {
      try SecureDirectory.rejectNonEmptyExtendedACL(
        on: descriptor,
        description: path
      )
    } catch {
      Darwin.close(descriptor)
      throw error
    }
    guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
      Darwin.close(descriptor)
      throw ManagerBackendError.operationInProgress
    }
    self.descriptor = descriptor
  }

  deinit {
    _ = Darwin.lockf(descriptor, F_ULOCK, 0)
    Darwin.close(descriptor)
  }
}
