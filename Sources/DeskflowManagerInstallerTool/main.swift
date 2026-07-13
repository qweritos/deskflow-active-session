import Darwin
import Foundation

private let applicationName = "Deskflow ASM.app"
private let canonicalPath = "/Applications/\(applicationName)"
private let stagePrefix = "staging."
private let operationLockPath = "/var/run/deskflow-active-session-manager.lock"
private let stateParentPath =
  "/Library/Application Support/io.github.qweritos.deskflow-active-session"
private let stateDirectoryPath = stateParentPath + "/state"
private let renewalJournalName = "manager-helper-renewal-required"

private func fail(_ message: String, code: Int32 = EX_USAGE) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  Darwin.exit(code)
}

private func durableSync(_ descriptor: Int32, description: String) {
  if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 { return }
  guard Darwin.fsync(descriptor) == 0 else {
    fail("Could not durably sync \(description).", code: EX_IOERR)
  }
}

private func validatedDirectory(_ path: String, allowGroupWrite: Bool = false) -> stat {
  let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  guard descriptor >= 0 else {
    fail("Refusing unsafe installation directory: \(path)", code: EX_NOPERM)
  }
  defer { Darwin.close(descriptor) }
  var metadata = stat()
  guard Darwin.fstat(descriptor, &metadata) == 0,
    metadata.st_mode & S_IFMT == S_IFDIR,
    metadata.st_uid == 0,
    metadata.st_mode & S_IWOTH == 0,
    allowGroupWrite || metadata.st_mode & S_IWGRP == 0
  else {
    fail("Refusing unsafe installation path: \(path)", code: EX_NOPERM)
  }
  rejectExtendedACL(descriptor, path: path)
  return metadata
}

private func validatedRegularFile(_ path: String, required: Bool = true) {
  let descriptor = Darwin.open(
    path,
    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
  )
  if descriptor < 0, errno == ENOENT, !required { return }
  guard descriptor >= 0 else {
    fail("Refusing unsafe installation file: \(path)", code: EX_NOPERM)
  }
  defer { Darwin.close(descriptor) }
  var metadata = stat()
  guard Darwin.fstat(descriptor, &metadata) == 0,
    metadata.st_mode & S_IFMT == S_IFREG,
    metadata.st_uid == 0,
    metadata.st_nlink == 1,
    metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
  else {
    fail("Refusing unsafe installation file: \(path)", code: EX_NOPERM)
  }
  rejectExtendedACL(descriptor, path: path)
}

private func rejectExtendedACL(_ descriptor: Int32, path: String) {
  errno = 0
  guard let acl = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
    if errno == ENOENT || errno == EOPNOTSUPP { return }
    fail("Could not inspect access controls on \(path).", code: EX_NOPERM)
  }
  defer { _ = Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
  var entry: acl_entry_t?
  if Darwin.acl_get_entry(acl, 0, &entry) == 0 {
    fail("Extended access controls are not allowed on \(path).", code: EX_NOPERM)
  }
  fail("Could not inspect access controls on \(path).", code: EX_NOPERM)
}

private func verifyInstalledApplication() {
  let contents = canonicalPath + "/Contents"
  for directory in [
    canonicalPath,
    contents,
    contents + "/MacOS",
    contents + "/Resources",
    contents + "/Library",
    contents + "/Library/LaunchDaemons",
  ] {
    _ = validatedDirectory(directory)
  }
  for file in [
    contents + "/Info.plist",
    contents + "/MacOS/Deskflow Active Session Manager",
    contents + "/MacOS/deskflow-manager-helper",
    contents + "/Resources/deskflow-session-supervisor",
    contents
      + "/Library/LaunchDaemons/io.github.qweritos.deskflow-active-session.manager-helper.plist",
  ] {
    validatedRegularFile(file)
  }
  validatedRegularFile(
    contents + "/Resources/deskflow-manager-installer-tool",
    required: false
  )
}

private func holdOperationLock() {
  let descriptor = Darwin.open(
    operationLockPath,
    O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
    S_IRUSR | S_IWUSR
  )
  guard descriptor >= 0 else {
    fail("Could not open the manager operation lock.", code: EX_NOPERM)
  }
  defer { Darwin.close(descriptor) }
  var metadata = stat()
  guard Darwin.fstat(descriptor, &metadata) == 0,
    metadata.st_mode & S_IFMT == S_IFREG,
    metadata.st_uid == 0,
    metadata.st_nlink == 1,
    Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
  else {
    fail("The manager operation lock is unsafe.", code: EX_NOPERM)
  }
  rejectExtendedACL(descriptor, path: operationLockPath)
  guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
    fail("The management helper is busy.", code: EX_TEMPFAIL)
  }
  FileHandle.standardOutput.write(Data("locked\n".utf8))
  while true {
    let input = FileHandle.standardInput.availableData
    if input.isEmpty || String(decoding: input, as: UTF8.self).contains("release") {
      break
    }
  }
  _ = Darwin.lockf(descriptor, F_ULOCK, 0)
}

private func openStateDirectory(create: Bool) -> Int32? {
  _ = validatedDirectory("/Library")
  _ = validatedDirectory("/Library/Application Support")
  for path in [stateParentPath, stateDirectoryPath] {
    var created = false
    if create {
      if Darwin.mkdir(path, 0o755) == 0 {
        created = true
      } else if errno != EEXIST {
        fail("Could not create the manager recovery directory.", code: EX_CANTCREAT)
      }
    } else {
      var metadata = stat()
      if Darwin.lstat(path, &metadata) != 0, errno == ENOENT { return nil }
    }
    let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      fail("The manager recovery directory is unsafe.", code: EX_NOPERM)
    }
    if created,
      Darwin.fchown(descriptor, 0, 0) != 0 || Darwin.fchmod(descriptor, 0o755) != 0
    {
      if descriptor >= 0 { Darwin.close(descriptor) }
      fail("The manager recovery directory is unsafe.", code: EX_NOPERM)
    }
    if created {
      durableSync(descriptor, description: path)
      let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
      let parent = Darwin.open(
        parentPath,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard parent >= 0 else {
        Darwin.close(descriptor)
        fail("Could not sync the manager recovery parent directory.", code: EX_IOERR)
      }
      durableSync(parent, description: parentPath)
      Darwin.close(parent)
    }
    Darwin.close(descriptor)
    _ = validatedDirectory(path)
  }
  let descriptor = Darwin.open(
    stateDirectoryPath,
    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
  )
  guard descriptor >= 0 else {
    fail("Could not open the manager recovery directory.", code: EX_NOPERM)
  }
  return descriptor
}

private func readRenewalJournal() -> String? {
  guard let directory = openStateDirectory(create: false) else { return nil }
  defer { Darwin.close(directory) }
  let descriptor = Darwin.openat(
    directory,
    renewalJournalName,
    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
  )
  if descriptor < 0, errno == ENOENT { return nil }
  guard descriptor >= 0 else {
    fail("The manager recovery journal is unsafe.", code: EX_NOPERM)
  }
  defer { Darwin.close(descriptor) }
  var metadata = stat()
  guard Darwin.fstat(descriptor, &metadata) == 0,
    metadata.st_mode & S_IFMT == S_IFREG,
    metadata.st_uid == 0,
    metadata.st_nlink == 1,
    metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
    metadata.st_size > 0,
    metadata.st_size <= 64
  else {
    fail("The manager recovery journal is unsafe.", code: EX_NOPERM)
  }
  rejectExtendedACL(descriptor, path: stateDirectoryPath + "/" + renewalJournalName)
  let data = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readDataToEndOfFile()
  let value = String(decoding: data, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard value == "enabled" || value == "requires-approval" else {
    fail("The manager recovery journal is invalid.", code: EX_DATAERR)
  }
  return value
}

private func writeRenewalJournal(_ value: String) {
  guard value == "enabled" || value == "requires-approval",
    let directory = openStateDirectory(create: true)
  else {
    fail("The manager recovery state is invalid.", code: EX_DATAERR)
  }
  defer { Darwin.close(directory) }
  let temporary = ".\(renewalJournalName).new.\(UUID().uuidString)"
  let descriptor = Darwin.openat(
    directory,
    temporary,
    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
    S_IRUSR | S_IWUSR
  )
  guard descriptor >= 0 else {
    fail("Could not stage the manager recovery journal.", code: EX_CANTCREAT)
  }
  defer { Darwin.close(descriptor) }
  let data = Data((value + "\n").utf8)
  var writeSucceeded = true
  data.withUnsafeBytes { bytes in
    guard var address = bytes.baseAddress else { return }
    var remaining = bytes.count
    while remaining > 0 {
      let count = Darwin.write(descriptor, address, remaining)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        writeSucceeded = false
        return
      }
      remaining -= count
      address = address.advanced(by: count)
    }
  }
  guard writeSucceeded,
    Darwin.fchown(descriptor, 0, 0) == 0,
    Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
  else {
    _ = Darwin.unlinkat(directory, temporary, 0)
    fail("Could not commit the manager recovery journal.", code: EX_CANTCREAT)
  }
  rejectExtendedACL(descriptor, path: stateDirectoryPath + "/" + temporary)
  durableSync(descriptor, description: "the manager recovery journal")
  guard Darwin.renameat(directory, temporary, directory, renewalJournalName) == 0 else {
    _ = Darwin.unlinkat(directory, temporary, 0)
    fail("Could not commit the manager recovery journal.", code: EX_CANTCREAT)
  }
  durableSync(directory, description: stateDirectoryPath)
}

private func clearRenewalJournal() {
  guard let directory = openStateDirectory(create: false) else { return }
  defer { Darwin.close(directory) }
  guard readRenewalJournal() != nil else { return }
  guard Darwin.unlinkat(directory, renewalJournalName, 0) == 0 else {
    fail("Could not clear the manager recovery journal.", code: EX_OSERR)
  }
  durableSync(directory, description: stateDirectoryPath)
}

guard geteuid() == 0 else {
  fail("The installer swap tool must run as root.", code: EX_NOPERM)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["hold-lock"] {
  holdOperationLock()
  Darwin.exit(EXIT_SUCCESS)
}
if arguments == ["verify-installed"] {
  verifyInstalledApplication()
  Darwin.exit(EXIT_SUCCESS)
}
if arguments == ["journal-read"] {
  print(readRenewalJournal() ?? "none")
  Darwin.exit(EXIT_SUCCESS)
}
if arguments.count == 2, arguments[0] == "journal-write" {
  writeRenewalJournal(arguments[1])
  Darwin.exit(EXIT_SUCCESS)
}
if arguments == ["journal-clear"] {
  clearRenewalJournal()
  Darwin.exit(EXIT_SUCCESS)
}
guard arguments.count == 3, arguments[0] == "swap" else {
  fail(
    "Usage: deskflow-manager-installer-tool {hold-lock|verify-installed|journal-read|journal-write STATUS|journal-clear|swap STAGED_APP INSTALLED_APP}"
  )
}

let stagedPath = URL(fileURLWithPath: arguments[1]).standardizedFileURL.path
let installedPath = URL(fileURLWithPath: arguments[2]).standardizedFileURL.path
guard installedPath == canonicalPath else {
  fail("The installed application path is not allowlisted.", code: EX_NOPERM)
}

let stageRoot = URL(fileURLWithPath: stagedPath).deletingLastPathComponent()
let stageRootName = stageRoot.lastPathComponent
guard stageRoot.deletingLastPathComponent().path == stateParentPath,
  stageRootName.hasPrefix(stagePrefix),
  !stageRootName.dropFirst(stagePrefix.count).isEmpty,
  URL(fileURLWithPath: stagedPath).lastPathComponent == applicationName
else {
  fail("The staged application path is not allowlisted.", code: EX_NOPERM)
}

_ = validatedDirectory("/Applications", allowGroupWrite: true)
_ = validatedDirectory("/Library")
_ = validatedDirectory("/Library/Application Support")
_ = validatedDirectory(stateParentPath)
let stageRootMetadata = validatedDirectory(stageRoot.path)
let stagedMetadata = validatedDirectory(stagedPath)
let installedMetadata = validatedDirectory(installedPath)
guard stageRootMetadata.st_dev == stagedMetadata.st_dev,
  stagedMetadata.st_dev == installedMetadata.st_dev
else {
  fail("Application exchange must stay on one filesystem.", code: EXDEV)
}

guard Darwin.renamex_np(stagedPath, installedPath, UInt32(RENAME_SWAP)) == 0 else {
  fail("Atomic application exchange failed with errno \(errno).", code: EX_OSERR)
}

for path in ["/Applications", stageRoot.path] {
  let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  if descriptor >= 0 {
    durableSync(descriptor, description: path)
    Darwin.close(descriptor)
  } else {
    fail("Could not sync the application exchange.", code: EX_IOERR)
  }
}
