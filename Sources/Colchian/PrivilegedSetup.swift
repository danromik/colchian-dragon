import Foundation

/// Installs a narrowly scoped sudoers rule so the app (and only the current user) can run the
/// three `pmset` commands it needs as root without a password. The administrator password is
/// requested once, through the standard macOS authentication dialog.
enum PrivilegedSetup {
    static let sudoersPath = "/etc/sudoers.d/colchian"

    /// True if the current user may run the disable-sleep command via sudo without a password.
    static var isInstalled: Bool {
        Shell.run(PowerManager.sudo, ["-n", "-l"] + PowerManager.disableCommand).succeeded
    }

    static func sudoersRule(for user: String) -> String {
        let commands = [PowerManager.enableCommand, PowerManager.disableCommand, PowerManager.sleepNowCommand]
            .map { $0.joined(separator: " ") }
            .joined(separator: ", ")
        return """
        # Installed by Colchian Dragon.app to toggle lid-close sleep without a password.
        # Remove in Colchian Dragon Settings, or with: sudo rm \(sudoersPath)
        \(user) ALL=(root) NOPASSWD: \(commands)

        """
    }

    /// Returns nil on success or an error message.
    static func install() -> String? {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return "Unsupported user name: \(user)"
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("colchian-sudoers-\(UUID().uuidString)")
        do {
            try sudoersRule(for: user).write(to: temp, atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        defer { try? FileManager.default.removeItem(at: temp) }

        // Validate with visudo before installing: a malformed sudoers file can break sudo entirely.
        let command = "/usr/sbin/visudo -cf \(Shell.quote(temp.path)) && "
            + "/usr/bin/install -m 0440 -o root -g wheel \(Shell.quote(temp.path)) \(sudoersPath)"
        if let error = Shell.runAsAdministrator(command, prompt: "Colchian Dragon needs your permission to control lid-close sleep. You will only be asked once.") {
            return error
        }
        return isInstalled ? nil : "The rule was installed but sudo does not accept it. Check that /etc/sudoers includes /private/etc/sudoers.d."
    }

    /// Re-enables sleep and removes the sudoers rule. Returns nil on success or an error message.
    static func uninstall() -> String? {
        Shell.runAsAdministrator("\(PowerManager.enableCommand.joined(separator: " ")); /bin/rm -f \(sudoersPath)",
                                 prompt: "Colchian Dragon wants to remove its permission to control lid-close sleep.")
    }
}
