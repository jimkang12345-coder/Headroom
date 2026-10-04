import Foundation

public protocol NetworkTransport: Sendable {
    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Standard URLSession transport with streaming reception byte limits and redirect rejection
public final class SecureURLSessionTransport: NSObject, NetworkTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!
    public let maxResponseBytes: Int

    public init(timeoutInterval: TimeInterval = 15.0, maxResponseBytes: Int = 65536) {
        self.maxResponseBytes = maxResponseBytes
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutInterval
        config.timeoutIntervalForResource = timeoutInterval
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: self)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw DeepSeekError.invalidResponseFormat
            }

            // Early check on Content-Length if specified
            if httpResponse.expectedContentLength > 0 && httpResponse.expectedContentLength > Int64(maxResponseBytes) {
                throw DeepSeekError.responseTooLarge
            }

            var data = Data()
            data.reserveCapacity(min(maxResponseBytes, max(1024, Int(httpResponse.expectedContentLength))))

            // Enforce response limit DURING reception, aborting immediately if exceeded
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxResponseBytes {
                    throw DeepSeekError.responseTooLarge
                }
            }

            return (data, httpResponse)
        } catch let error as DeepSeekError {
            throw error
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
                throw DeepSeekError.offline
            case .timedOut:
                throw DeepSeekError.timeout
            case .cancelled:
                throw DeepSeekError.cancelled
            default:
                throw DeepSeekError.networkError
            }
        } catch {
            throw DeepSeekError.networkError
        }
    }

    // URLSessionTaskDelegate: Strictly reject redirects
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Disallow all HTTP redirects to protect Bearer credentials
        completionHandler(nil)
    }
}

/// Mock transport for deterministic offline tests
public final class MockNetworkTransport: NetworkTransport, @unchecked Sendable {
    public typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private var handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func setHandler(_ handler: @escaping Handler) {
        self.handler = handler
    }

    public func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await handler(request)
    }
}
