import Foundation
import Darwin

/// Publishes a backup only after its new file is private. Unlike Foundation's
/// replacement API, rename does not copy permissions or ACLs from an old backup.
public enum PrivateSnapshotExporter {
    public enum ExportError: Error, LocalizedError {
        case invalidDestination
        case protectionUnavailable

        public var errorDescription: String? {
            switch self {
            case .invalidDestination:
                return "Choose a regular backup file, not a folder or symbolic link."
            case .protectionUnavailable:
                return "This destination could not enforce private backup permissions. Choose a local folder that supports owner-only access."
            }
        }
    }

    public static func write(_ data: Data, to destination: URL) throws {
        try publish(to: destination) { descriptor in
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw systemError() }
                    offset += written
                }
            }
        }
    }

    /// The writer runs only after protection succeeds; a failed writer never
    /// replaces the destination. Kept internal for failure-path regression tests.
    static func publish(to destination: URL, contents: (Int32) throws -> Void) throws {
        let name = destination.lastPathComponent
        guard destination.isFileURL, !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw ExportError.invalidDestination
        }
        let parent = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw systemError() }
        defer { close(parent) }

        var existing = stat()
        if fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG else { throw ExportError.invalidDestination }
        } else if errno != ENOENT {
            throw systemError()
        }

        // A private directory prevents another local directory user from swapping
        // the staged file. Open descriptors also anchor all later operations if
        // an ancestor directory is renamed while the export is in progress.
        let stageName = ".headroom-export-" + UUID().uuidString
        guard mkdirat(parent, stageName, 0o700) == 0 else { throw systemError() }
        defer { unlinkat(parent, stageName, AT_REMOVEDIR) }
        let stage = openat(parent, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else { throw systemError() }
        defer { close(stage) }
        try protect(stage, mode: 0o700, type: S_IFDIR)

        let temporaryName = "snapshot.json"
        let file = openat(stage, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw systemError() }
        defer {
            close(file)
            unlinkat(stage, temporaryName, 0)
        }
        try protect(file, mode: 0o600, type: S_IFREG)
        try contents(file)
        guard fsync(file) == 0 else { throw systemError() }
        try verifyProtection(file, mode: 0o600, type: S_IFREG)
        guard renameat(stage, temporaryName, parent, name) == 0 else { throw systemError() }
    }

    private static func protect(_ descriptor: Int32, mode: mode_t, type: mode_t) throws {
        // New objects can inherit an ACL even when initially created with 0600.
        // Clear only our new staging objects, never the selected folder/old file.
        guard fchmod(descriptor, mode) == 0, let emptyACL = acl_init(0) else {
            throw ExportError.protectionUnavailable
        }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        guard acl_set_fd(descriptor, emptyACL) == 0 else { throw ExportError.protectionUnavailable }
        try verifyProtection(descriptor, mode: mode, type: type)
    }

    private static func verifyProtection(_ descriptor: Int32, mode: mode_t, type: mode_t) throws {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_uid == geteuid(), attributes.st_mode & S_IFMT == type,
              attributes.st_mode & 0o7777 == mode else {
            throw ExportError.protectionUnavailable
        }
        errno = 0
        guard let permissions = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            // Darwin reports ENOENT when a file has no extended ACL at all.
            guard errno == ENOENT else { throw ExportError.protectionUnavailable }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(permissions)) }
        var entry: acl_entry_t?
        errno = 0
        guard acl_get_entry(permissions, ACL_FIRST_ENTRY.rawValue, &entry) == -1, errno == EINVAL else {
            throw ExportError.protectionUnavailable
        }
    }

    private static func systemError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
