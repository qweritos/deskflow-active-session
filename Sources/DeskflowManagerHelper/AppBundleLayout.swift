import Darwin
import DeskflowManagerCore
import Foundation
import MachO
import Security

struct AppBundleLayout {
  let appURL: URL
  let supervisorPayload: Data
  let supervisorDesignatedRequirement: String
  let appDesignatedRequirement: String

  init() throws {
    let invokedHelper = try Self.executableURL()
    guard invokedHelper.lastPathComponent == ManagerConstants.helperExecutableName else {
      throw ManagerBackendError.invalidPayload("Manager helper executable name is unexpected.")
    }

    var executable = invokedHelper
    for _ in 0..<3 {
      executable.deleteLastPathComponent()
    }
    guard executable.pathExtension == "app",
      let bundle = Bundle(url: executable),
      bundle.bundleIdentifier == ManagerConstants.appBundleIdentifier,
      executable.path
        == "/Applications/\(ManagerConstants.managerExecutableName).app"
    else {
      throw ManagerBackendError.invalidPayload(
        "Manager helper is not in the expected signed application bundle."
      )
    }

    let expectedHelper =
      executable
      .appendingPathComponent("Contents/MacOS", isDirectory: true)
      .appendingPathComponent(ManagerConstants.helperExecutableName)
      .standardizedFileURL
    guard expectedHelper.path == invokedHelper.path else {
      throw ManagerBackendError.invalidPayload("Manager helper path is unexpected.")
    }

    let payload =
      executable
      .appendingPathComponent("Contents/Resources", isDirectory: true)
      .appendingPathComponent(ManagerConstants.supervisorResourceName)
      .standardizedFileURL
    guard
      payload.deletingLastPathComponent().deletingLastPathComponent().path
        == executable.appendingPathComponent("Contents").standardizedFileURL.path
    else {
      throw ManagerBackendError.invalidPayload("Supervisor payload path escaped the app bundle.")
    }

    try Self.validateRootOwnedBundleDirectories(executable)
    let capturedPayload = try Self.capturePayload(at: payload) {
      try Self.designatedRequirement(
        for: executable,
        expectedIdentifier: ManagerConstants.appBundleIdentifier,
        strict: true
      )
    }

    appURL = executable
    supervisorPayload = capturedPayload.data
    supervisorDesignatedRequirement = capturedPayload.requirement
    appDesignatedRequirement = capturedPayload.appRequirement
  }

  private static func executableURL() throws -> URL {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    guard size > 1, size <= UInt32(PATH_MAX * 4) else {
      throw ManagerBackendError.invalidPayload(
        "Could not determine the manager helper executable path."
      )
    }

    var buffer = [CChar](repeating: 0, count: Int(size))
    let result = buffer.withUnsafeMutableBufferPointer { pointer in
      _NSGetExecutablePath(pointer.baseAddress, &size)
    }
    guard result == 0 else {
      throw ManagerBackendError.invalidPayload(
        "Could not determine the manager helper executable path."
      )
    }

    let reportedPath = String(cString: buffer)
    guard let resolvedPath = Darwin.realpath(reportedPath, nil) else {
      throw ManagerBackendError.invalidPayload(
        "Could not resolve the manager helper executable path."
      )
    }
    defer { Darwin.free(resolvedPath) }
    return URL(fileURLWithPath: String(cString: resolvedPath)).standardizedFileURL
  }

  private static func capturePayload(
    at payloadURL: URL,
    validateApp: () throws -> String
  ) throws -> (data: Data, requirement: String, appRequirement: String) {
    let descriptor = Darwin.open(
      payloadURL.path,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw ManagerBackendError.invalidPayload("Could not open the sealed supervisor payload.")
    }
    defer { Darwin.close(descriptor) }

    var opened = stat()
    guard Darwin.fstat(descriptor, &opened) == 0,
      opened.st_mode & S_IFMT == S_IFREG,
      opened.st_uid == 0,
      opened.st_nlink == 1,
      opened.st_mode & (S_IWGRP | S_IWOTH) == 0,
      opened.st_size > 0,
      opened.st_size <= 64 * 1_024 * 1_024
    else {
      throw ManagerBackendError.invalidPayload(
        "The sealed supervisor payload has unsafe ownership, permissions, or size."
      )
    }
    try rejectExtendedACL(descriptor, description: "the sealed supervisor payload")

    let appRequirement = try validateApp()
    var current = stat()
    guard Darwin.lstat(payloadURL.path, &current) == 0,
      current.st_mode & S_IFMT == S_IFREG,
      current.st_dev == opened.st_dev,
      current.st_ino == opened.st_ino,
      current.st_size == opened.st_size
    else {
      throw ManagerBackendError.invalidPayload(
        "The supervisor payload changed while the application seal was checked."
      )
    }

    let requirement = try designatedRequirement(
      for: payloadURL,
      expectedIdentifier: ManagerConstants.supervisorIdentifier,
      strict: true
    )
    let data = try readAll(descriptor, size: Int(opened.st_size))
    var afterRead = stat()
    guard Darwin.fstat(descriptor, &afterRead) == 0,
      afterRead.st_dev == opened.st_dev,
      afterRead.st_ino == opened.st_ino,
      afterRead.st_size == opened.st_size
    else {
      throw ManagerBackendError.invalidPayload(
        "The supervisor payload changed while it was captured."
      )
    }

    let verifiedAppRequirement = try validateApp()
    let verifiedRequirement = try designatedRequirement(
      for: payloadURL,
      expectedIdentifier: ManagerConstants.supervisorIdentifier,
      strict: true
    )
    var verifiedPath = stat()
    guard Darwin.lstat(payloadURL.path, &verifiedPath) == 0,
      verifiedPath.st_dev == opened.st_dev,
      verifiedPath.st_ino == opened.st_ino,
      verifiedPath.st_size == opened.st_size,
      verifiedAppRequirement == appRequirement,
      verifiedRequirement == requirement,
      Darwin.lseek(descriptor, 0, SEEK_SET) == 0,
      try readAll(descriptor, size: Int(opened.st_size)) == data
    else {
      throw ManagerBackendError.invalidPayload(
        "The captured supervisor payload did not survive post-capture verification."
      )
    }
    return (data, requirement, appRequirement)
  }

  private static func readAll(_ descriptor: Int32, size: Int) throws -> Data {
    var data = Data(count: size)
    var offset = 0
    let completed = data.withUnsafeMutableBytes { bytes -> Bool in
      guard let base = bytes.baseAddress else { return false }
      while offset < size {
        let count = Darwin.read(descriptor, base.advanced(by: offset), size - offset)
        if count > 0 {
          offset += count
        } else if count < 0, errno == EINTR {
          continue
        } else {
          return false
        }
      }
      return true
    }
    guard completed, offset == size else {
      throw ManagerBackendError.invalidPayload("Could not read the sealed supervisor payload.")
    }
    return data
  }

  private static func validateRootOwnedBundleDirectories(_ appURL: URL) throws {
    let directories = [
      appURL,
      appURL.appendingPathComponent("Contents", isDirectory: true),
      appURL.appendingPathComponent("Contents/MacOS", isDirectory: true),
      appURL.appendingPathComponent("Contents/Resources", isDirectory: true),
    ]
    for directory in directories {
      let descriptor = Darwin.open(
        directory.path,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard descriptor >= 0 else {
        throw ManagerBackendError.invalidPayload(
          "The manager application bundle contains an unsafe directory."
        )
      }
      defer { Darwin.close(descriptor) }
      var metadata = stat()
      guard Darwin.fstat(descriptor, &metadata) == 0,
        metadata.st_mode & S_IFMT == S_IFDIR,
        metadata.st_uid == 0,
        metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
      else {
        throw ManagerBackendError.invalidPayload(
          "The manager application bundle has unsafe ownership or permissions."
        )
      }
      try rejectExtendedACL(descriptor, description: directory.path)
    }

    let helperURL =
      appURL
      .appendingPathComponent("Contents/MacOS", isDirectory: true)
      .appendingPathComponent(ManagerConstants.helperExecutableName)
    let helper = Darwin.open(helperURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard helper >= 0 else {
      throw ManagerBackendError.invalidPayload("The manager helper executable is unsafe.")
    }
    defer { Darwin.close(helper) }
    var helperMetadata = stat()
    guard Darwin.fstat(helper, &helperMetadata) == 0,
      helperMetadata.st_mode & S_IFMT == S_IFREG,
      helperMetadata.st_uid == 0,
      helperMetadata.st_nlink == 1,
      helperMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else {
      throw ManagerBackendError.invalidPayload(
        "The manager helper has unsafe ownership or permissions."
      )
    }
    try rejectExtendedACL(helper, description: helperURL.path)
  }

  private static func rejectExtendedACL(_ descriptor: Int32, description: String) throws {
    errno = 0
    guard let acl = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
      if errno == ENOENT || errno == EOPNOTSUPP { return }
      throw ManagerBackendError.invalidPayload(
        "Could not inspect access controls on \(description)."
      )
    }
    defer { _ = Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    if Darwin.acl_get_entry(acl, 0, &entry) == 0 {
      throw ManagerBackendError.invalidPayload(
        "Extended access controls are not allowed on \(description)."
      )
    }
    throw ManagerBackendError.invalidPayload(
      "Could not inspect access controls on \(description)."
    )
  }

  private static func designatedRequirement(
    for codeURL: URL,
    expectedIdentifier: String,
    strict: Bool
  ) throws -> String {
    var code: SecStaticCode?
    var status = SecStaticCodeCreateWithPath(codeURL as CFURL, [], &code)
    guard status == errSecSuccess, let code else {
      throw ManagerBackendError.invalidPayload("Could not inspect a bundled code signature.")
    }
    let validationFlags =
      strict
      ? SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
      : SecCSFlags()
    status = SecStaticCodeCheckValidity(code, validationFlags, nil)
    guard status == errSecSuccess else {
      throw ManagerBackendError.invalidPayload("A bundled code signature is invalid (\(status)).")
    }

    var information: CFDictionary?
    status = SecCodeCopySigningInformation(
      code,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &information
    )
    let identifier = (information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String
    guard status == errSecSuccess, identifier == expectedIdentifier else {
      throw ManagerBackendError.invalidPayload("A bundled signing identifier is unexpected.")
    }

    var requirement: SecRequirement?
    status = SecCodeCopyDesignatedRequirement(code, [], &requirement)
    guard status == errSecSuccess, let requirement else {
      throw ManagerBackendError.invalidPayload("Bundled code has no designated requirement.")
    }
    var text: CFString?
    status = SecRequirementCopyString(requirement, [], &text)
    guard status == errSecSuccess, let text else {
      throw ManagerBackendError.invalidPayload("Could not serialize a bundled code requirement.")
    }
    return text as String
  }
}
