import Foundation
import HTTPTypes
import Hummingbird

/// Serves the built dashboard behind the token check. Real routes win: files are only tried
/// after the router answers 404.
struct DashboardFilesMiddleware: RouterMiddleware {
    enum DirectoryStatus: Equatable { case missing, empty, ready }

    let root: String
    private let files: FileMiddleware<FrameRequestContext, LocalFileSystem>

    init(config: Config) {
        root = config.dashboardDir
        files = FileMiddleware(config.dashboardDir, searchForIndexHtml: true)
    }

    func handle(
        _ request: Request,
        context: FrameRequestContext,
        next: (Request, FrameRequestContext) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as HTTPResponseError where error.status == .notFound {}

        let path = request.uri.path
        if path == "/api" || path.hasPrefix("/api/") { return try APIError.notFound.response() }

        // FileMiddleware answers 400 for "..", so reject here first.
        guard let decoded = path.removingPercentEncoding, !decoded.contains("..") else {
            return try APIError.notFound.response()
        }
        // Resolve both sides: temp dirs and symlinks must not lead out of the root.
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let target = URL(fileURLWithPath: root + decoded).resolvingSymlinksInPath().path
        guard target == resolvedRoot || target.hasPrefix(resolvedRoot + "/") else {
            return try APIError.notFound.response()
        }

        var response: Response
        do {
            response = try await files.handle(request, context: context) { _, _ in throw HTTPError(.notFound) }
        } catch let error as HTTPResponseError where error.status == .notFound {
            return try APIError.notFound.response()
        }
        switch response.status {
        case .ok, .partialContent, .notModified:
            response.headers[.cacheControl] = Self.cacheControl(forPath: decoded)
        default: break
        }
        return response
    }

    /// Vite's hashed files under /assets/ never change. Everything else is revalidated.
    static func cacheControl(forPath path: String) -> String {
        path.hasPrefix("/assets/") ? "public, max-age=31536000, immutable" : "no-cache"
    }

    static func directoryStatus(_ path: String) -> DirectoryStatus {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return .missing }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return contents.isEmpty ? .empty : .ready
    }
}
