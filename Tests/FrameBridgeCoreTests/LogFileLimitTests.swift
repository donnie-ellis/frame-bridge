import Foundation
import Testing

@testable import FrameBridgeCore

private func openLog() -> (path: String, fd: Int32) {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("fb-log-\(UUID().uuidString).log").path
    return (path, open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644))
}

private func write(_ fd: Int32, _ text: String) {
    _ = text.withCString { Darwin.write(fd, $0, strlen($0)) }
}

@Test func aLogPastTheLimitIsKeptAsDotOneAndEmptied() throws {
    let (path, fd) = openLog()
    defer { close(fd) }
    write(fd, "old line one\nold line two\n")
    #expect(LogFileLimit.rotateIfNeeded(fd: fd, limit: 10))
    #expect(try String(contentsOfFile: path + ".1", encoding: .utf8) == "old line one\nold line two\n")
    write(fd, "new\n")
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "new\n")
}

@Test func aLogUnderTheLimitIsLeftAlone() throws {
    let (path, fd) = openLog()
    defer { close(fd) }
    write(fd, "short\n")
    #expect(!LogFileLimit.rotateIfNeeded(fd: fd, limit: 1000))
    #expect(!FileManager.default.fileExists(atPath: path + ".1"))
}

@Test func aPipeIsLeftAlone() {
    var fds: [Int32] = [0, 0]
    pipe(&fds)
    defer { close(fds[0]); close(fds[1]) }
    #expect(!LogFileLimit.rotateIfNeeded(fd: fds[1], limit: 0))
}
