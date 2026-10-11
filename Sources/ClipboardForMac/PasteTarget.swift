import AppKit

@MainActor
enum PasteTarget {
    static func waitUntilFrontmost(
        _ pid: pid_t,
        maxChecks: Int = 31,
        intervalNanoseconds: UInt64 = 50_000_000,
        frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    ) async -> Bool {
        guard maxChecks > 0 else { return false }
        for check in 0..<maxChecks {
            if Task.isCancelled { return false }
            if frontmostPID() == pid { return true }
            if check + 1 < maxChecks {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        }
        return false
    }
}
