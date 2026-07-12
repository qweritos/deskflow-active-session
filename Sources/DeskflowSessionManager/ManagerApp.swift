import Darwin
import DeskflowManagerCore
import Foundation
import ServiceManagement
import SwiftUI

private func helperStatusName(_ status: SMAppService.Status) -> String {
  switch status {
  case .notRegistered: return "not-registered"
  case .enabled: return "enabled"
  case .requiresApproval: return "requires-approval"
  case .notFound: return "not-found"
  @unknown default: return "unknown"
  }
}

@main
struct DeskflowSessionManagerApp: App {
  @StateObject private var model = ManagerModel()

  init() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--version"] {
      print(ManagerConstants.managerVersion)
      Darwin.exit(EXIT_SUCCESS)
    }
    if arguments == ["--helper-status"] {
      let service = SMAppService.daemon(
        plistName: ManagerConstants.helperPlistName
      )
      print(helperStatusName(service.status))
      Darwin.exit(EXIT_SUCCESS)
    }
    if arguments == ["--helper-version"] {
      let client = HelperClient()
      Task {
        do {
          print(try await client.version())
          Darwin.exit(EXIT_SUCCESS)
        } catch {
          fputs("\(error.localizedDescription)\n", stderr)
          Darwin.exit(EXIT_FAILURE)
        }
      }
      dispatchMain()
    }
    if arguments == ["--register-helper"] {
      let service = SMAppService.daemon(
        plistName: ManagerConstants.helperPlistName
      )
      do {
        try service.register()
        print(helperStatusName(service.status))
        Darwin.exit(EXIT_SUCCESS)
      } catch let error as NSError {
        fputs("\(error.domain) \(error.code): \(error.localizedDescription)\n", stderr)
        print(helperStatusName(service.status))
        Darwin.exit(EXIT_FAILURE)
      }
    }
    if arguments == ["--unregister-helper"] {
      let service = SMAppService.daemon(
        plistName: ManagerConstants.helperPlistName
      )
      service.unregister { error in
        if let error = error as NSError? {
          fputs("\(error.domain) \(error.code): \(error.localizedDescription)\n", stderr)
          print("unknown")
          Darwin.exit(EXIT_FAILURE)
        }
        print("not-registered")
        Darwin.exit(EXIT_SUCCESS)
      }
      dispatchMain()
    }
  }

  var body: some Scene {
    WindowGroup {
      ManagerView()
        .environmentObject(model)
    }
    .windowStyle(.titleBar)
    .commands {
      CommandGroup(after: .appInfo) {
        Button("Refresh Status") { model.refresh() }
          .keyboardShortcut("r", modifiers: .command)
          .disabled(!model.helperState.allowsStatus || model.isRefreshing)
      }
    }
  }
}
