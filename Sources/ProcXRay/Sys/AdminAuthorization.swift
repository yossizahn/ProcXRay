import Foundation
import Security

/// An administrator's authorization, for the one helper call that runs a program of the caller's choosing as root
/// (HelperProtocol.launch). Every other helper call reads, and is open to any admin caller; this one does what
/// `sudo` does, so like sudo it asks for an administrator's password (or Touch ID) first, every time. The app
/// gets the right from the Security agent and hands its external form to the helper, which checks it with no
/// interaction: a form that doesn't hold the right, or that came from a process that never asked, fails.
enum AdminAuthorization {
    static let right = "system.privilege.admin"

    /// An authorization the user granted just now; the helper must check it while `release` hasn't run.
    struct Grant {
        let externalForm: Data
        let release: () -> Void
    }

    /// Shows the Security agent's prompt; blocks until the user answers, so not on the main thread.
    static func request(prompt: String) -> Result<Grant, LaunchError> {
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else {
            return .failure(LaunchError(message: "Couldn't ask for authorization."))
        }
        let status = copyRight(ref, flags: [.interactionAllowed, .extendRights, .preAuthorize], prompt: prompt)
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(ref, [])
            if status == errAuthorizationCanceled { return .failure(LaunchError(message: "Cancelled.")) }
            return .failure(LaunchError(message: "Not authorized (\(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"))."))
        }
        var ext = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(ref, &ext) == errAuthorizationSuccess else {
            AuthorizationFree(ref, [])
            return .failure(LaunchError(message: "Couldn't pass the authorization on."))
        }
        let data = withUnsafeBytes(of: &ext) { Data($0) }
        return .success(Grant(externalForm: data, release: { AuthorizationFree(ref, []) }))
    }

    /// In the helper: whether `externalForm` holds the right now, without asking anyone.
    static func verify(_ externalForm: Data) -> Bool {
        guard externalForm.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var ext = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &ext) { _ = externalForm.copyBytes(to: $0) }
        var ref: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&ext, &ref) == errAuthorizationSuccess, let ref else { return false }
        defer { AuthorizationFree(ref, []) }
        return copyRight(ref, flags: [.extendRights], prompt: nil) == errAuthorizationSuccess
    }

    private static func copyRight(_ ref: AuthorizationRef, flags: AuthorizationFlags, prompt: String?) -> OSStatus {
        right.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { ip in
                var rights = AuthorizationRights(count: 1, items: ip)
                guard let prompt else { return AuthorizationCopyRights(ref, &rights, nil, flags, nil) }
                return kAuthorizationEnvironmentPrompt.withCString { key in
                    prompt.withCString { text in
                        var envItem = AuthorizationItem(name: key, valueLength: strlen(text),
                                                        value: UnsafeMutableRawPointer(mutating: text), flags: 0)
                        return withUnsafeMutablePointer(to: &envItem) { ep in
                            var env = AuthorizationEnvironment(count: 1, items: ep)
                            return AuthorizationCopyRights(ref, &rights, &env, flags, nil)
                        }
                    }
                }
            }
        }
    }
}
