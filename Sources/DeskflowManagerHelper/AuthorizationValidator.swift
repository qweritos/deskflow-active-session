import DeskflowManagerCore
import Foundation
import Security

enum AuthorizationValidator {
  static func validateAdministratorRight(_ data: Data) throws {
    guard data.count == MemoryLayout<AuthorizationExternalForm>.size else {
      throw ManagerBackendError.permissionDenied("Administrator authorization has an invalid size.")
    }

    var externalForm = AuthorizationExternalForm()
    _ = withUnsafeMutableBytes(of: &externalForm) { destination in
      data.copyBytes(to: destination)
    }

    var authorization: AuthorizationRef?
    let importStatus = AuthorizationCreateFromExternalForm(
      &externalForm,
      &authorization
    )
    guard importStatus == errAuthorizationSuccess, let authorization else {
      throw ManagerBackendError.permissionDenied(
        "Administrator authorization could not be imported (\(importStatus))."
      )
    }
    defer { AuthorizationFree(authorization, [.destroyRights]) }

    let status = kAuthorizationRightExecute.withCString { rightName in
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
          [],
          nil
        )
      }
    }
    guard status == errAuthorizationSuccess else {
      throw ManagerBackendError.permissionDenied(
        "Administrator authorization is missing or expired (\(status))."
      )
    }
  }
}
