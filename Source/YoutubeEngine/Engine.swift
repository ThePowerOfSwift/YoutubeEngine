import Foundation
import ReactiveSwift

public final class Engine {
    public enum Authorization {
        case key(String)
        case accessToken(String)
    }

    private let session: URLSession
    private let authorization: Authorization
    // swiftlint:disable:next force_unwrapping
    private let baseURL = URL(string: "https://www.googleapis.com/youtube/v3")!
    private let logger: Logging?

    init(authorization: Authorization, session: URLSession, logger: Logging?) {
        self.session = session
        self.authorization = authorization
        self.logger = logger
    }

    public convenience init(authorization: Authorization, isLogEnabled: Bool = false) {
        let configuration = URLSessionConfiguration.default
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            configuration.httpAdditionalHeaders = ["X-Ios-Bundle-Identifier": bundleIdentifier]
        }
        self.init(authorization: authorization,
                  session: URLSession(configuration: configuration),
                  logger: isLogEnabled ? ConsoleLogger() : nil)
    }

    public func cancelAllRequests() {
        session.invalidateAndCancel()
    }

    public func videos(_ request: VideoRequest) -> SignalProducer<Page<Video>, NSError> {
        return page(for: request)
    }

    public func channels(_ request: ChannelRequest) -> SignalProducer<Page<Channel>, NSError> {
        return page(for: request)
    }

    public func search(_ request: SearchRequest) -> SignalProducer<Page<SearchItem>, NSError> {
        return page(for: request)
            .flatMap(.latest) { page -> SignalProducer<Page<SearchItem>, NSError> in
                let videosParts =
                    self.load(parts: request.videoParts.filter { $0 != request.part },
                              for: page.items.compactMap { $0.video })

                let channelParts =
                    self.load(parts: request.channelParts.filter { $0 != request.part },
                              for: page.items.compactMap { $0.channel })

                return SignalProducer.combineLatest(videosParts, channelParts)
                    .map { videosById, channelsById -> Page<SearchItem> in
                        let mergedItems: [SearchItem] = page.items.map { item in
                            if let itemVideo = item.video, let video = videosById[itemVideo.id] {
                                return .videoItem(itemVideo.merged(with: video))
                            } else if let itemChannel = item.channel, let channel = channelsById[itemChannel.id] {
                                return .channelItem(itemChannel.merged(with: channel))
                            }
                            return item
                        }
                        return Page(items: mergedItems,
                                    totalCount: page.totalCount,
                                    nextPageToken: page.nextPageToken,
                                    previousPageToken: page.previousPageToken)
                    }
                    .promoteError(NSError.self)
            }
    }

    private func load<T: Decodable & PartibleObject & SearchableObject>(
        parts: [Part],
        for objects: [T]
    ) -> SignalProducer<[String: T], Never> {
        if parts.isEmpty {
            return SignalProducer(value: [:])
        }

        if objects.isEmpty {
            return SignalProducer(value: [:])
        }

        return page(for: T.request(for: parts, objects: objects))
            .map { page in
                var objectsById: [String: T] = [:]
                page.items.forEach {
                    objectsById[$0.id] = $0
                }
                return objectsById
            }
            .flatMapError { _ in SignalProducer(value: [:]) }
    }

    private func object<T: Decodable>(of type: T.Type, request: YoutubeRequest) -> SignalProducer<T, NSError> {
        let url = baseURL.appendingPathComponent(request.command)

        var parameters: [String: String] = request.parameters
        switch authorization {
        case .accessToken(let token):
            parameters["access_token"] = token
        case .key(let key):
            parameters["key"] = key
        }

        return session.objectSignal(method: request.method,
                                    url: url,
                                    parameters: parameters,
                                    logger: logger)
    }

    private func page<R: PageRequest>(for request: R) -> SignalProducer<Page<R.Item>, NSError> where R.Item: Decodable {
        return object(of: Page<R.Item>.self, request: request)
    }
}
