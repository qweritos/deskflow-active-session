import Darwin
import Foundation

internal final class SecureDirectory {
  let descriptor: Int32
  let path: String

  init(descriptor: Int32, path: String) {
    self.descriptor = descriptor
    self.path = path
  }

  deinit {
    Darwin.close(descriptor)
  }

  static func openAbsolute(
    _ path: String,
    finalOwner: uid_t
  ) throws -> SecureDirectory {
    guard path.hasPrefix("/"), !path.contains("\0") else {
      throw ManagerBackendError.unsafeFileSystem("Unsafe directory path: \(path.managerBounded)")
    }

    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
      throw ManagerBackendError.unsafeFileSystem("Directory traversal is not allowed.")
    }

    var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard current >= 0 else {
      throw ManagerBackendError.unsafeFileSystem("Could not open the filesystem root.")
    }

    if components.isEmpty {
      try validateDirectory(current, owner: 0, description: "/")
      return SecureDirectory(descriptor: current, path: "/")
    }

    var traversed = ""
    do {
      for (index, componentValue) in components.enumerated() {
        let component = String(componentValue)
        traversed += "/" + component
        let next = Darwin.openat(
          current,
          component,
          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard next >= 0 else {
          throw ManagerBackendError.unsafeFileSystem(
            "Refusing unsafe or missing directory: \(traversed.managerBounded)"
          )
        }
        Darwin.close(current)
        current = next

        let expectedOwner: uid_t = index == components.count - 1 ? finalOwner : 0
        try validateDirectory(current, owner: expectedOwner, description: traversed)
      }
      return SecureDirectory(descriptor: current, path: path)
    } catch {
      Darwin.close(current)
      throw error
    }
  }

  func childDirectory(
    _ name: String,
    create: Bool,
    owner: uid_t,
    group: gid_t,
    mode: mode_t
  ) throws -> SecureDirectory? {
    try Self.validateComponent(name)
    var child = Darwin.openat(
      descriptor,
      name,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )

    if child < 0, errno == ENOENT, create {
      guard Darwin.mkdirat(descriptor, name, mode) == 0 || errno == EEXIST else {
        throw ManagerBackendError.unsafeFileSystem("Could not create \(path)/\(name).")
      }
      child = Darwin.openat(
        descriptor,
        name,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard child >= 0 else {
        throw ManagerBackendError.unsafeFileSystem("Could not safely open \(path)/\(name).")
      }
      guard Darwin.fchown(child, owner, group) == 0, Darwin.fchmod(child, mode) == 0 else {
        Darwin.close(child)
        throw ManagerBackendError.unsafeFileSystem("Could not set ownership on \(path)/\(name).")
      }
    } else if child < 0, errno == ENOENT {
      return nil
    } else if child < 0 {
      throw ManagerBackendError.unsafeFileSystem(
        "Refusing symlink or unsafe directory: \(path)/\(name)"
      )
    }

    do {
      try Self.validateDirectory(child, owner: owner, description: "\(path)/\(name)")
      return SecureDirectory(descriptor: child, path: "\(path)/\(name)")
    } catch {
      Darwin.close(child)
      throw error
    }
  }

  func readRegularFile(
    _ name: String,
    maximumBytes: Int,
    expectedOwner: uid_t? = nil,
    requireOwnerOnlyWrite: Bool = false
  ) throws -> Data? {
    try Self.validateComponent(name)
    let file = Darwin.openat(
      descriptor,
      name,
      O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
    )
    if file < 0, errno == ENOENT { return nil }
    guard file >= 0 else {
      throw ManagerBackendError.unsafeFileSystem("Refusing unsafe file: \(path)/\(name)")
    }
    defer { Darwin.close(file) }

    var metadata = stat()
    guard Darwin.fstat(file, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_nlink == 1,
      metadata.st_size >= 0,
      metadata.st_size <= maximumBytes,
      expectedOwner == nil || metadata.st_uid == expectedOwner,
      !requireOwnerOnlyWrite || metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else {
      throw ManagerBackendError.unsafeFileSystem(
        "Refusing non-regular or oversized file: \(path)/\(name)")
    }
    if expectedOwner == 0 {
      try Self.rejectNonEmptyExtendedACL(
        on: file,
        description: "\(path)/\(name)"
      )
    }

    return try Self.readAll(file, maximumBytes: maximumBytes)
  }

  func atomicWrite(
    _ data: Data,
    named name: String,
    owner: uid_t,
    group: gid_t,
    mode: mode_t
  ) throws {
    try Self.validateComponent(name)
    let temporary = ".\(name).new.\(UUID().uuidString)"
    let file = Darwin.openat(
      descriptor,
      temporary,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard file >= 0 else {
      throw ManagerBackendError.unsafeFileSystem("Could not stage \(path)/\(name).")
    }

    var committed = false
    defer {
      Darwin.close(file)
      if !committed { _ = Darwin.unlinkat(descriptor, temporary, 0) }
    }

    try Self.writeAll(data, to: file)
    guard Darwin.fchown(file, owner, group) == 0,
      Darwin.fchmod(file, mode) == 0
    else {
      throw ManagerBackendError.unsafeFileSystem("Could not finalize \(path)/\(name).")
    }
    if owner == 0 {
      try Self.rejectNonEmptyExtendedACL(
        on: file,
        description: "\(path)/\(temporary)"
      )
    }
    guard Darwin.fsync(file) == 0 else {
      throw ManagerBackendError.unsafeFileSystem("Could not sync \(path)/\(name).")
    }
    guard Darwin.renameat(descriptor, temporary, descriptor, name) == 0 else {
      throw ManagerBackendError.unsafeFileSystem("Could not atomically replace \(path)/\(name).")
    }
    _ = Darwin.fsync(descriptor)
    committed = true
  }

  func removeRegularFile(
    _ name: String,
    expectedData: Data? = nil,
    expectedOwner: uid_t? = nil,
    requireOwnerOnlyWrite: Bool = false
  ) throws -> Bool {
    try Self.validateComponent(name)
    let quarantine = ".\(name).remove.\(UUID().uuidString)"
    guard
      Darwin.renameatx_np(
        descriptor,
        name,
        descriptor,
        quarantine,
        UInt32(RENAME_EXCL)
      ) == 0
    else {
      if errno == ENOENT { return false }
      throw ManagerBackendError.unsafeFileSystem(
        "Could not quarantine \(path)/\(name) before removal."
      )
    }
    _ = Darwin.fsync(descriptor)

    do {
      let file = Darwin.openat(
        descriptor,
        quarantine,
        O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
      )
      guard file >= 0 else {
        throw ManagerBackendError.unsafeFileSystem(
          "Quarantined file is unsafe: \(path)/\(name)"
        )
      }
      defer { Darwin.close(file) }

      var openedMetadata = stat()
      guard Darwin.fstat(file, &openedMetadata) == 0,
        openedMetadata.st_mode & S_IFMT == S_IFREG,
        openedMetadata.st_nlink == 1,
        openedMetadata.st_size >= 0,
        openedMetadata.st_size <= 64 * 1_024 * 1_024,
        expectedOwner == nil || openedMetadata.st_uid == expectedOwner,
        !requireOwnerOnlyWrite
          || openedMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0
      else {
        throw ManagerBackendError.unsafeFileSystem(
          "Quarantined file metadata is unsafe: \(path)/\(name)"
        )
      }
      if expectedOwner == 0 {
        try Self.rejectNonEmptyExtendedACL(
          on: file,
          description: "\(path)/\(name)"
        )
      }

      let current = try Self.readAll(file, maximumBytes: 64 * 1_024 * 1_024)
      if let expectedData, current != expectedData {
        throw ManagerBackendError.unsafeFileSystem(
          "File changed before removal: \(path)/\(name)"
        )
      }

      var anchoredMetadata = stat()
      guard
        Darwin.fstatat(
          descriptor,
          quarantine,
          &anchoredMetadata,
          AT_SYMLINK_NOFOLLOW
        ) == 0,
        anchoredMetadata.st_dev == openedMetadata.st_dev,
        anchoredMetadata.st_ino == openedMetadata.st_ino,
        anchoredMetadata.st_mode & S_IFMT == S_IFREG,
        anchoredMetadata.st_nlink == 1
      else {
        throw ManagerBackendError.unsafeFileSystem(
          "Quarantined file lost its anchored identity: \(path)/\(name)"
        )
      }

      guard Darwin.unlinkat(descriptor, quarantine, 0) == 0 else {
        throw ManagerBackendError.unsafeFileSystem("Could not remove \(path)/\(name).")
      }
      _ = Darwin.fsync(descriptor)
      return true
    } catch {
      let restoreResult = Darwin.renameatx_np(
        descriptor,
        quarantine,
        descriptor,
        name,
        UInt32(RENAME_EXCL)
      )
      _ = Darwin.fsync(descriptor)
      guard restoreResult == 0 else {
        throw ManagerBackendError.unsafeFileSystem(
          "Removal was aborted, but the quarantined file could not be restored safely."
        )
      }
      throw error
    }
  }

  private static func validateDirectory(
    _ descriptor: Int32,
    owner: uid_t,
    description: String
  ) throws {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == owner,
      metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else {
      throw ManagerBackendError.unsafeFileSystem(
        "Refusing directory with unsafe type, owner, or permissions: \(description.managerBounded)"
      )
    }
    if owner == 0 {
      try rejectNonEmptyExtendedACL(on: descriptor, description: description)
    }
  }

  static func rejectNonEmptyExtendedACL(
    on descriptor: Int32,
    description: String
  ) throws {
    errno = 0
    guard let acl = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
      if errno == ENOENT || errno == EOPNOTSUPP { return }
      throw ManagerBackendError.unsafeFileSystem(
        "Could not verify the ACL on \(description.managerBounded)."
      )
    }
    defer { _ = Darwin.acl_free(UnsafeMutableRawPointer(acl)) }

    var entry: acl_entry_t?
    let result = Darwin.acl_get_entry(acl, 0, &entry)
    if result == 0 {
      throw ManagerBackendError.unsafeFileSystem(
        "Refusing trusted path with an extended ACL: \(description.managerBounded)"
      )
    }
    throw ManagerBackendError.unsafeFileSystem(
      "Could not inspect the ACL on \(description.managerBounded)."
    )
  }

  private static func validateComponent(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
      throw ManagerBackendError.unsafeFileSystem("Unsafe path component.")
    }
  }

  private static func readAll(_ descriptor: Int32, maximumBytes: Int) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { return result }
      if count < 0, errno == EINTR { continue }
      guard count > 0, result.count + count <= maximumBytes else {
        throw ManagerBackendError.unsafeFileSystem("File exceeds the permitted size.")
      }
      result.append(buffer, count: count)
    }
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard var address = rawBuffer.baseAddress else { return }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let count = Darwin.write(descriptor, address, remaining)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw ManagerBackendError.unsafeFileSystem("Could not write staged file.")
        }
        remaining -= count
        address = address.advanced(by: count)
      }
    }
  }
}

internal enum SecureFileSystem {
  static func readRegularFile(at path: String, maximumBytes: Int) throws -> Data {
    guard path.hasPrefix("/"), !path.hasSuffix("/") else {
      throw ManagerBackendError.unsafeFileSystem("Unsafe file path.")
    }
    let url = URL(fileURLWithPath: path)
    let parent = try SecureDirectory.openAbsolute(
      url.deletingLastPathComponent().path,
      finalOwner: 0
    )
    guard
      let data = try parent.readRegularFile(
        url.lastPathComponent,
        maximumBytes: maximumBytes,
        expectedOwner: 0,
        requireOwnerOnlyWrite: true
      )
    else {
      throw ManagerBackendError.missingPayload("Missing file: \(path.managerBounded)")
    }
    return data
  }
}
