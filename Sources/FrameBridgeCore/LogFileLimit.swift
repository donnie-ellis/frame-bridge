import Foundation
import ServiceLifecycle

/// Under launchd, stderr (where the logs go) is `~/Library/Logs/frame-bridge/frame-bridge.log`,
/// set by `scripts/install.sh`. Every request is logged at `info`, so the file is kept under
/// `limit`: past it, it is copied to `frame-bridge.log.1` and emptied in place (launchd holds the
/// descriptor, so it can't be renamed). A terminal or a pipe is left alone.
enum LogFileLimit {
    static let limit: off_t = 10 << 20

    /// Returns whether it rotated.
    @discardableResult
    static func rotateIfNeeded(fd: Int32, limit: off_t = limit) -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > limit else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return false }
        let path = String(cString: buffer)
        let previous = path + ".1"
        unlink(previous)
        guard copyfile(path, previous, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else { return false }
        ftruncate(fd, 0)
        // Without O_APPEND the next write would land at the old offset.
        lseek(fd, 0, SEEK_SET)
        return true
    }
}

/// Checks stderr at start and then hourly.
struct LogFileLimitService: Service {
    func run() async throws {
        await cancelWhenGracefulShutdown {
            while !Task.isCancelled {
                LogFileLimit.rotateIfNeeded(fd: STDERR_FILENO)
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }
}
