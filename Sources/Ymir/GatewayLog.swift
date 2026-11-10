import Foundation
import Darwin

enum GatewayLog {
    /// Rotate only before launching a child: its inherited stdout/stderr handles
    /// must keep pointing at the active log for the lifetime of the process.
    static func open(at url: URL, maxBytes: Int = 10 * 1024 * 1024) throws -> FileHandle {
        let files = FileManager.default
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: url.path) {
            let attributes = try files.attributesOfItem(atPath: url.path)
            if ((attributes[.size] as? NSNumber)?.intValue ?? 0) >= maxBytes {
                for index in stride(from: 3, through: 1, by: -1) {
                    let destination = URL(fileURLWithPath: url.path + ".\(index)")
                    let source = index == 1 ? url : URL(fileURLWithPath: url.path + ".\(index - 1)")
                    if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
                    if files.fileExists(atPath: source.path) { try files.moveItem(at: source, to: destination) }
                }
            }
        }
        // O_APPEND also protects against overlapping inherited handles during
        // shutdown. O_CREAT without O_TRUNC preserves earlier gateway sessions.
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
