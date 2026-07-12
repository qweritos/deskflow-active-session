import Darwin
import Foundation

public enum FixedExecutable: Sendable {
  case dscl
  case launchctl
  case ps
  case lsof

  public var absolutePath: String {
    switch self {
    case .dscl:
      return "/usr/bin/dscl"
    case .launchctl:
      return "/bin/launchctl"
    case .ps:
      return "/bin/ps"
    case .lsof:
      return "/usr/sbin/lsof"
    }
  }
}

public struct ProcessResult: Sendable {
  public let terminationStatus: Int32
  public let stdout: String
  public let stderr: String
  public let timedOut: Bool

  public init(
    terminationStatus: Int32,
    stdout: String,
    stderr: String,
    timedOut: Bool
  ) {
    self.terminationStatus = terminationStatus
    self.stdout = stdout
    self.stderr = stderr
    self.timedOut = timedOut
  }
}

public final class FixedProcessRunner: @unchecked Sendable {
  private static let pollIntervalMilliseconds: Int32 = 50
  private static let terminationGrace: TimeInterval = 1
  private static let killGrace: TimeInterval = 2
  private static let readBufferSize = 16_384

  private let maximumOutputBytes: Int

  public init(maximumOutputBytes: Int = 262_144) {
    self.maximumOutputBytes = max(0, maximumOutputBytes)
  }

  public func run(
    _ executable: FixedExecutable,
    arguments: [String],
    timeout: TimeInterval = 10
  ) throws -> ProcessResult {
    guard timeout.isFinite, timeout >= 0 else {
      throw ManagerBackendError.invalidRequest(
        "Process timeout must be a finite, nonnegative interval."
      )
    }

    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    let didTerminate = DispatchSemaphore(value: 0)

    process.executableURL = URL(fileURLWithPath: executable.absolutePath)
    process.arguments = arguments
    process.environment = [
      "LANG": "C",
      "LC_ALL": "C",
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = standardOutput
    process.standardError = standardError
    process.terminationHandler = { _ in didTerminate.signal() }

    let outputReader = standardOutput.fileHandleForReading
    let errorReader = standardError.fileHandleForReading
    let outputWriter = standardOutput.fileHandleForWriting
    let errorWriter = standardError.fileHandleForWriting

    defer {
      try? outputReader.close()
      try? errorReader.close()
      try? outputWriter.close()
      try? errorWriter.close()
    }

    try Self.makeNonblocking(outputReader.fileDescriptor)
    try Self.makeNonblocking(errorReader.fileDescriptor)
    try process.run()

    // Process has duplicated these descriptors for the child. Closing the
    // parent's copies lets the readers observe EOF when the child exits.
    try? outputWriter.close()
    try? errorWriter.close()

    var output = BoundedOutput(maximumBytes: maximumOutputBytes)
    var error = BoundedOutput(maximumBytes: maximumOutputBytes)
    var outputIsOpen = true
    var errorIsOpen = true
    var phase = TerminationPhase.running
    var phaseDeadline = Self.deadline(after: timeout)
    var timedOut = false

    do {
      processLoop: while true {
        if outputIsOpen {
          outputIsOpen = try Self.drain(
            outputReader.fileDescriptor,
            into: &output
          )
        }
        if errorIsOpen {
          errorIsOpen = try Self.drain(
            errorReader.fileDescriptor,
            into: &error
          )
        }

        if didTerminate.wait(timeout: .now()) == .success {
          break processLoop
        }

        let now = DispatchTime.now().uptimeNanoseconds
        if now >= phaseDeadline {
          switch phase {
          case .running:
            timedOut = true
            if process.isRunning {
              process.terminate()
            }
            phase = .terminating
            phaseDeadline = Self.deadline(after: Self.terminationGrace)

          case .terminating:
            if process.isRunning {
              _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            phase = .killing
            phaseDeadline = Self.deadline(after: Self.killGrace)

          case .killing:
            throw ManagerBackendError.processFailed(
              "Process did not exit after SIGTERM and SIGKILL."
            )
          }
          continue
        }

        Self.poll(
          outputDescriptor: outputIsOpen ? outputReader.fileDescriptor : nil,
          errorDescriptor: errorIsOpen ? errorReader.fileDescriptor : nil,
          until: phaseDeadline
        )
      }

      // The child is reaped, so all bytes it wrote are now readable. Drain
      // once more without waiting for descendants that inherited a pipe.
      if outputIsOpen {
        _ = try Self.drain(outputReader.fileDescriptor, into: &output)
      }
      if errorIsOpen {
        _ = try Self.drain(errorReader.fileDescriptor, into: &error)
      }
    } catch {
      Self.stop(process, didTerminate: didTerminate)
      throw error
    }

    return ProcessResult(
      terminationStatus: process.terminationStatus,
      stdout: String(decoding: output.data, as: UTF8.self),
      stderr: String(decoding: error.data, as: UTF8.self),
      timedOut: timedOut
    )
  }

  private static func makeNonblocking(_ descriptor: Int32) throws {
    let flags = Darwin.fcntl(descriptor, F_GETFL)
    guard flags >= 0,
      Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0
    else {
      throw ManagerBackendError.processFailed(
        "Could not configure process output capture."
      )
    }
  }

  /// Drains all currently available data and returns whether the pipe remains open.
  private static func drain(
    _ descriptor: Int32,
    into output: inout BoundedOutput
  ) throws -> Bool {
    var buffer = [UInt8](repeating: 0, count: readBufferSize)

    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count > 0 {
        output.append(buffer, count: count)
        continue
      }
      if count == 0 {
        return false
      }

      switch errno {
      case EINTR:
        continue
      case EAGAIN:
        return true
      default:
        throw ManagerBackendError.processFailed(
          "Could not read captured process output."
        )
      }
    }
  }

  private static func poll(
    outputDescriptor: Int32?,
    errorDescriptor: Int32?,
    until deadline: UInt64
  ) {
    var descriptors: [pollfd] = []
    if let outputDescriptor {
      descriptors.append(
        pollfd(fd: outputDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
      )
    }
    if let errorDescriptor {
      descriptors.append(
        pollfd(fd: errorDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
      )
    }

    let wait = pollMilliseconds(until: deadline)
    if descriptors.isEmpty {
      if wait > 0 {
        Darwin.usleep(useconds_t(wait) * 1_000)
      }
      return
    }

    descriptors.withUnsafeMutableBufferPointer { buffer in
      _ = Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), wait)
    }
  }

  private static func pollMilliseconds(until deadline: UInt64) -> Int32 {
    let now = DispatchTime.now().uptimeNanoseconds
    guard deadline > now else { return 0 }

    let remaining = deadline - now
    let milliseconds =
      remaining / 1_000_000
      + (remaining % 1_000_000 == 0 ? 0 : 1)
    return Int32(min(UInt64(pollIntervalMilliseconds), milliseconds))
  }

  private static func deadline(after interval: TimeInterval) -> UInt64 {
    let now = DispatchTime.now().uptimeNanoseconds
    let available = UInt64.max - now
    let nanoseconds = interval * 1_000_000_000
    guard nanoseconds < Double(available) else { return UInt64.max }
    return now + UInt64(nanoseconds)
  }

  private static func stop(
    _ process: Process,
    didTerminate: DispatchSemaphore
  ) {
    guard process.isRunning else { return }

    process.terminate()
    if didTerminate.wait(timeout: .now() + .milliseconds(100)) == .success {
      return
    }
    if process.isRunning {
      _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
    _ = didTerminate.wait(timeout: .now() + .seconds(1))
  }
}

private enum TerminationPhase {
  case running
  case terminating
  case killing
}

private struct BoundedOutput {
  let maximumBytes: Int
  private(set) var data = Data()

  mutating func append(_ bytes: [UInt8], count: Int) {
    let remaining = maximumBytes - data.count
    guard remaining > 0 else { return }
    data.append(contentsOf: bytes.prefix(min(remaining, count)))
  }
}
