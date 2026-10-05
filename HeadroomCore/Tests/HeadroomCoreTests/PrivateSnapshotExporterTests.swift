import XCTest
import Darwin
@testable import HeadroomCore

final class PrivateSnapshotExporterTests: XCTestCase {
    private func inDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func assertPrivate(_ descriptor: Int32, file: StaticString = #filePath, line: UInt = #line) throws {
        var attributes = stat()
        XCTAssertEqual(fstat(descriptor, &attributes), 0, file: file, line: line)
        XCTAssertEqual(attributes.st_uid, geteuid(), file: file, line: line)
        XCTAssertEqual(attributes.st_mode & 0o7777, 0o600, file: file, line: line)
        errno = 0
        guard let permissions = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            XCTAssertEqual(errno, ENOENT, file: file, line: line)
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(permissions)) }
        var entry: acl_entry_t?
        XCTAssertEqual(acl_get_entry(permissions, ACL_FIRST_ENTRY.rawValue, &entry), -1, file: file, line: line)
        XCTAssertEqual(errno, EINVAL, file: file, line: line)
    }

    func testProtectionPrecedesPrivateBytesAndPreservesJSON() throws {
        try inDirectory { directory in
            let destination = directory.appendingPathComponent("backup.json")
            let data = Data(#"{"synthetic":"backup","amount":"-0.50"}"#.utf8)
            try PrivateSnapshotExporter.publish(to: destination) { descriptor in
                try assertPrivate(descriptor)
                var attributes = stat()
                XCTAssertEqual(fstat(descriptor, &attributes), 0)
                XCTAssertEqual(attributes.st_size, 0, "Protection must precede the first byte")
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
            }
            XCTAssertEqual(try Data(contentsOf: destination), data)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["backup.json"])
        }
    }

    func testReplacementDoesNotRetainPermissiveMetadataOrExposeNewBytesToOldReader() throws {
        try inDirectory { directory in
            let destination = directory.appendingPathComponent("backup.json")
            let old = Data("old synthetic backup".utf8), new = Data("new private synthetic backup".utf8)
            try old.write(to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
            let reader = try FileHandle(forReadingFrom: destination)
            defer { try? reader.close() }
            try PrivateSnapshotExporter.write(new, to: destination)
            XCTAssertEqual(try reader.readToEnd(), old)
            let published = try FileHandle(forReadingFrom: destination)
            defer { try? published.close() }
            try assertPrivate(published.fileDescriptor)
            XCTAssertEqual(try published.readToEnd(), new)
        }
    }

    func testWriteFailurePreservesExistingBackupAndRemovesStaging() throws {
        try inDirectory { directory in
            let destination = directory.appendingPathComponent("backup.json")
            let original = Data("original".utf8)
            try original.write(to: destination)
            var wrotePartialData = false
            XCTAssertThrowsError(try PrivateSnapshotExporter.publish(to: destination) { descriptor in
                try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: Data("partial".utf8))
                wrotePartialData = true
                throw POSIXError(.EIO)
            })
            XCTAssertTrue(wrotePartialData)
            XCTAssertEqual(try Data(contentsOf: destination), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["backup.json"])
        }
    }

    func testSymlinkAndDirectoryDestinationsAreRejectedWithoutChangingTargets() throws {
        try inDirectory { directory in
            let target = directory.appendingPathComponent("original.json")
            let link = directory.appendingPathComponent("link.json")
            let original = Data("original".utf8)
            try original.write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try PrivateSnapshotExporter.write(Data("new".utf8), to: link))
            XCTAssertEqual(try Data(contentsOf: target), original)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
            XCTAssertThrowsError(try PrivateSnapshotExporter.write(Data(), to: directory))
        }
    }

    func testMissingParentAndPublishFailureNeverReportSuccessOrLeaveStaging() throws {
        try inDirectory { directory in
            var invoked = false
            XCTAssertThrowsError(try PrivateSnapshotExporter.publish(to: directory.appendingPathComponent("missing/backup.json")) { _ in invoked = true })
            XCTAssertFalse(invoked)
            let destination = directory.appendingPathComponent("backup.json")
            XCTAssertThrowsError(try PrivateSnapshotExporter.publish(to: destination) { descriptor in
                try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: Data("new".utf8))
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            })
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["backup.json"])
            XCTAssertTrue(try destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        }
    }

    #if os(macOS)
    func testInheritedACLIsRemovedBeforeWritingWithoutChangingParentACL() throws {
        try inDirectory { directory in
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/bin/chmod")
            command.arguments = ["+a", "everyone allow read,readattr,readextattr,readsecurity,file_inherit,directory_inherit", directory.path]
            try command.run()
            command.waitUntilExit()
            XCTAssertEqual(command.terminationStatus, 0)
            guard command.terminationStatus == 0 else { return }
            let destination = directory.appendingPathComponent("backup.json")
            try PrivateSnapshotExporter.publish(to: destination) { descriptor in
                try assertPrivate(descriptor)
                try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: Data("private".utf8))
            }
            let parentACL = try XCTUnwrap(acl_get_file(directory.path, ACL_TYPE_EXTENDED))
            defer { acl_free(UnsafeMutableRawPointer(parentACL)) }
            var entry: acl_entry_t?
            XCTAssertEqual(acl_get_entry(parentACL, ACL_FIRST_ENTRY.rawValue, &entry), 0, "The selected folder ACL must remain untouched")
            let published = try FileHandle(forReadingFrom: destination)
            defer { try? published.close() }
            try assertPrivate(published.fileDescriptor)
        }
    }
    #endif
}
