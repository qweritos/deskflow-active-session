import AppKit
import CoreGraphics
import Darwin
import Foundation

private let programVersion = "0.2.0"

private struct Options {
  var corePath =
    ProcessInfo.processInfo.environment["DESKFLOW_CORE"]
    ?? "/Applications/Deskflow.app/Contents/MacOS/deskflow-core"
  var settingsPath: String?
  var activationDelay = 0.2
  var stopTimeout = 4.0
  var checkOnly = false
}

private enum ArgumentError: Error, CustomStringConvertible {
  case missingValue(String)
  case invalidNumber(option: String, value: String)
  case unknownOption(String)

  var description: String {
    switch self {
    case .missingValue(let option):
      return "missing value for \(option)"
    case .invalidNumber(let option, let value):
      return "invalid value for \(option): \(value)"
    case .unknownOption(let option):
      return "unknown option: \(option)"
    }
  }
}

private func usage() -> String {
  """
  Usage: deskflow-session-supervisor [options]

  Runs Deskflow's CLI server only while this user's macOS desktop session is active.

    --core PATH                  deskflow-core executable
    --settings PATH              optional Deskflow settings override
    --activation-delay SECONDS   delay after session activation (default: 0.2)
    --stop-timeout SECONDS       graceful shutdown timeout (default: 4.0)
    --check                      validate configuration and print session state
    --version                    print version
    -h, --help                   show this help
  """
}

private func positiveNumber(_ value: String, option: String) throws -> Double {
  guard let number = Double(value), number.isFinite, number >= 0 else {
    throw ArgumentError.invalidNumber(option: option, value: value)
  }
  return number
}

private func parseOptions() throws -> Options {
  var options = Options()
  let arguments = Array(CommandLine.arguments.dropFirst())
  var index = 0

  func value(after option: String) throws -> String {
    let valueIndex = index + 1
    guard valueIndex < arguments.count else {
      throw ArgumentError.missingValue(option)
    }
    index = valueIndex
    return arguments[valueIndex]
  }

  while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--core":
      options.corePath = try value(after: argument)
    case "--settings":
      options.settingsPath = try value(after: argument)
    case "--activation-delay":
      let raw = try value(after: argument)
      options.activationDelay = try positiveNumber(raw, option: argument)
    case "--stop-timeout":
      let raw = try value(after: argument)
      options.stopTimeout = try positiveNumber(raw, option: argument)
    case "--check":
      options.checkOnly = true
    case "--version":
      print(programVersion)
      Darwin.exit(EXIT_SUCCESS)
    case "-h", "--help":
      print(usage())
      Darwin.exit(EXIT_SUCCESS)
    default:
      throw ArgumentError.unknownOption(argument)
    }
    index += 1
  }

  return options
}

private func currentSessionIsOnConsole() -> Bool {
  guard
    let session = CGSessionCopyCurrentDictionary() as? [String: Any],
    session["kCGSSessionOnConsoleKey"] as? Bool == true
  else {
    return false
  }

  return session["kCGSessionLoginDoneKey"] as? Bool ?? true
}

private final class ProcessLock {
  private let descriptor: Int32

  init?() {
    let fileManager = FileManager.default
    let cacheDirectory = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Caches", isDirectory: true)
    do {
      try fileManager.createDirectory(
        at: cacheDirectory,
        withIntermediateDirectories: true
      )
    } catch {
      return nil
    }

    let path =
      cacheDirectory
      .appendingPathComponent("deskflow-active-session.lock").path
    let descriptor = Darwin.open(
      path,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { return nil }
    guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
      Darwin.close(descriptor)
      return nil
    }
    self.descriptor = descriptor
  }

  deinit {
    Darwin.lockf(descriptor, F_ULOCK, 0)
    Darwin.close(descriptor)
  }
}

private func validate(_ options: Options) -> Bool {
  let fileManager = FileManager.default
  var valid = true

  print("core: \(options.corePath)")
  if fileManager.isExecutableFile(atPath: options.corePath) {
    print("core executable: yes")
  } else {
    print("core executable: no")
    valid = false
  }

  if let settingsPath = options.settingsPath {
    print("settings: \(settingsPath)")
    if !fileManager.isReadableFile(atPath: settingsPath) {
      print("settings readable: no")
      valid = false
    } else {
      print("settings readable: yes")
    }
  } else {
    let defaultPath = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Deskflow/Deskflow.conf").path
    print("settings: default (\(defaultPath))")
  }

  print("desktop session: \(currentSessionIsOnConsole() ? "active" : "inactive")")
  print("accessibility: \(AXIsProcessTrusted() ? "yes" : "no")")
  return valid
}

private final class DeskflowSessionSupervisor: @unchecked Sendable {
  private let options: Options
  private let coreURL: URL
  private let processLock: ProcessLock
  private let workspaceCenter = NSWorkspace.shared.notificationCenter

  private var observers: [NSObjectProtocol] = []
  private var signalSources: [DispatchSourceSignal] = []
  private var child: Process?
  private var pendingStart: DispatchWorkItem?
  private var sessionIsActive = false
  private var generation = 0
  private var retryDelay = 0.5
  private var shuttingDown = false

  init(options: Options, processLock: ProcessLock) {
    self.options = options
    self.processLock = processLock
    coreURL = URL(fileURLWithPath: options.corePath)
  }

  func run() -> Never {
    observeSessionChanges()
    observeTerminationSignals()
    reconcile(reason: "startup")
    RunLoop.main.run()
    fatalError("main run loop exited")
  }

  private func observeSessionChanges() {
    observers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.sessionDidBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.handleSessionBecameActive()
      }
    )

    observers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.sessionDidResignActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.deactivate(reason: "desktop session resigned active state")
      }
    )
  }

  private func observeTerminationSignals() {
    for signalNumber in [SIGTERM, SIGINT] {
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(
        signal: signalNumber,
        queue: .main
      )
      source.setEventHandler { [weak self] in
        self?.shutdown(signal: signalNumber)
      }
      source.resume()
      signalSources.append(source)
    }
  }

  private func handleSessionBecameActive() {
    DispatchQueue.main.asyncAfter(
      deadline: .now() + options.activationDelay
    ) { [weak self] in
      self?.reconcile(reason: "desktop session became active")
    }
  }

  private func reconcile(reason: String) {
    guard !shuttingDown else { return }

    if currentSessionIsOnConsole() {
      activate(reason: reason)
    } else {
      deactivate(reason: reason)
    }
  }

  private func activate(reason: String) {
    if !sessionIsActive {
      sessionIsActive = true
      generation += 1
      retryDelay = 0.5
      log("active: \(reason)")
    }

    scheduleStart(after: 0)
  }

  private func deactivate(reason: String) {
    let stateChanged = sessionIsActive
    sessionIsActive = false
    generation += 1
    pendingStart?.cancel()
    pendingStart = nil

    if stateChanged || child != nil {
      log("inactive: \(reason)")
    }
    stopChild()
  }

  private func scheduleStart(after delay: TimeInterval) {
    guard sessionIsActive, child == nil, pendingStart == nil else { return }

    let scheduledGeneration = generation
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.pendingStart = nil
      guard
        self.sessionIsActive,
        self.generation == scheduledGeneration,
        currentSessionIsOnConsole()
      else {
        self.reconcile(reason: "pre-start state check")
        return
      }
      self.startChild()
    }

    pendingStart = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  private func startChild() {
    guard child == nil, sessionIsActive else { return }

    let process = Process()
    process.executableURL = coreURL
    process.arguments = ["server"]
    if let settingsPath = options.settingsPath {
      process.arguments?.append(contentsOf: ["--settings", settingsPath])
    }
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    process.terminationHandler = { [weak self] terminated in
      let pid = terminated.processIdentifier
      let status = terminated.terminationStatus
      let reason = terminated.terminationReason.rawValue
      DispatchQueue.main.async { [weak self] in
        guard let self, self.child?.processIdentifier == pid else { return }
        self.child = nil
        self.log(
          "server exited: status=\(status) reason=\(reason)"
        )
        self.retryIfStillActive()
      }
    }

    do {
      try process.run()
      child = process
      log("server started: pid=\(process.processIdentifier)")

      DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
        [weak self, weak process] in
        guard
          let self,
          let process,
          self.child === process,
          process.isRunning
        else {
          return
        }
        self.retryDelay = 0.5
      }
    } catch {
      log("server launch failed: \(error.localizedDescription)")
      retryIfStillActive()
    }
  }

  private func retryIfStillActive() {
    guard !shuttingDown, sessionIsActive, currentSessionIsOnConsole() else {
      return
    }

    let delay = retryDelay
    retryDelay = min(retryDelay * 2, 15)
    log("retrying server in \(String(format: "%.1f", delay))s")
    scheduleStart(after: delay)
  }

  private func stopChild() {
    guard let process = child else { return }

    let pid = process.processIdentifier
    if process.isRunning {
      log("stopping server: pid=\(pid)")
      process.terminate()
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + options.stopTimeout) {
      [weak self] in
      guard
        let self,
        !self.sessionIsActive,
        self.child?.processIdentifier == pid,
        self.child?.isRunning == true
      else {
        return
      }

      self.log("force-stopping server: pid=\(pid)")
      if Darwin.kill(pid, SIGKILL) != 0 && errno != ESRCH {
        self.log("could not force-stop server: pid=\(pid) errno=\(errno)")
      }
    }
  }

  private func shutdown(signal signalNumber: Int32) {
    guard !shuttingDown else { return }
    shuttingDown = true
    sessionIsActive = false
    generation += 1
    pendingStart?.cancel()
    pendingStart = nil
    log("supervisor stopping: signal=\(signalNumber)")
    stopChild()

    DispatchQueue.main.asyncAfter(deadline: .now() + options.stopTimeout + 0.2) {
      Darwin.exit(EXIT_SUCCESS)
    }
  }

  private func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(timestamp) deskflow-session-supervisor: \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
  }
}

do {
  let options = try parseOptions()
  if options.checkOnly {
    Darwin.exit(validate(options) ? EXIT_SUCCESS : EXIT_FAILURE)
  }

  guard FileManager.default.isExecutableFile(atPath: options.corePath) else {
    FileHandle.standardError.write(
      Data("deskflow-session-supervisor: core is not executable: \(options.corePath)\n".utf8)
    )
    Darwin.exit(EX_CONFIG)
  }

  guard let processLock = ProcessLock() else {
    FileHandle.standardError.write(
      Data("deskflow-session-supervisor: another supervisor is already running\n".utf8)
    )
    Darwin.exit(EX_TEMPFAIL)
  }

  let supervisor = DeskflowSessionSupervisor(
    options: options,
    processLock: processLock
  )
  supervisor.run()
} catch {
  FileHandle.standardError.write(
    Data("deskflow-session-supervisor: \(error)\n\n\(usage())\n".utf8)
  )
  Darwin.exit(EX_USAGE)
}
