import HTTPTypes
import Hummingbird
import Logging
import NIOCore

extension EventHub {
    nonisolated func addRoutes(to router: Router<FrameRequestContext>) {
        router.get("api/events") { _, context -> Response in
            let (id, stream) = await self.subscribe()
            let logger = context.logger
            logger.info("events connected")
            var headers = HTTPFields()
            headers[.contentType] = "text/event-stream"
            headers[.cacheControl] = "no-cache"
            return Response(status: .ok, headers: headers, body: ResponseBody { writer in
                do {
                    try await writer.write(ByteBuffer(string: SSE.retry))
                    for await chunk in stream {
                        try await writer.write(ByteBuffer(string: chunk))
                    }
                    await self.remove(id)
                    logger.info("events disconnected")
                    try await writer.finish(nil)
                } catch {
                    await self.remove(id)
                    logger.info("events disconnected")
                    throw error
                }
            })
        }
    }
}
