import Hummingbird
import Logging
import NIOCore

public struct FrameRequestContext: RequestContext, RemoteAddressRequestContext {
    public var coreContext: CoreRequestContextStorage
    /// nil under the HummingbirdTesting router framework.
    public let remoteAddress: SocketAddress?

    public init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
        self.remoteAddress = source.channel.remoteAddress
    }
}
