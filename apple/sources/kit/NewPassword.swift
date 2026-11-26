/// A password being chosen with its confirmation, as the join and change
/// password boards check it before the server does.
public struct NewPassword {
    public static let minimumLength = 12

    public var password: String
    public var confirmation: String

    public init(_ password: String, confirmation: String) {
        self.password = password
        self.confirmation = confirmation
    }

    /// Shown once something is typed.
    public var passwordError: String? {
        !password.isEmpty && password.count < Self.minimumLength ? "Use at least 12 characters." : nil
    }

    public var confirmationError: String? {
        !confirmation.isEmpty && confirmation != password ? "Passwords don't match." : nil
    }

    public var isValid: Bool { password.count >= Self.minimumLength && confirmation == password }
}
