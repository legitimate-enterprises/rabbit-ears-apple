import Foundation
import HTTPTypes
import OpenAPIRuntime
import RabbitEarsAPI

/// The server's shared error shape, thrown for every 4xx and 5xx answer.
public struct APIError: Error, Equatable, Sendable {
    public typealias Code = Components.Schemas._Error.CodePayload

    public let status: Int
    public let code: Code
    public let message: String
    /// Seconds from a 429's Retry-After.
    public let retryAfter: Int?
    /// The fields a 400 names.
    public let fields: [String]
    public let fieldMessages: [String: String]
    /// With off_air, when the station's next program starts; nil when none is scheduled.
    public let resumesAt: Date?

    public init(
        status: Int, code: Code, message: String, retryAfter: Int? = nil, fields: [String] = [],
        fieldMessages: [String: String] = [:], resumesAt: Date? = nil
    ) {
        self.status = status
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
        self.fields = fields
        self.fieldMessages = fieldMessages
        self.resumesAt = resumesAt
    }

    /// The APIError inside an error the generated client threw, if any.
    public static func from(_ error: any Error) -> APIError? {
        if let error = error as? APIError { return error }
        if let error = error as? ClientError { return from(error.underlyingError) }
        return nil
    }
}

/// Turns error responses into thrown `APIError`s so callers read only the
/// success case of each operation.
struct ErrorMiddleware: ClientMiddleware {
    var locked: (@MainActor @Sendable () -> Void)?

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        let status = response.status.code
        guard status >= 400 else { return (response, responseBody) }
        var data = Data()
        if let responseBody { data = try await Data(collecting: responseBody, upTo: 1 << 16) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try ServerDates().decode(decoder.singleValueContainer().decode(String.self))
        }
        if let decoded = try? decoder.decode(Components.Schemas._Error.self, from: data) {
            if decoded.code == .deviceLocked { await locked?() }
            let fields = decoded.fields ?? []
            throw APIError(
                status: status, code: decoded.code, message: decoded.message,
                retryAfter: response.headerFields[.retryAfter].flatMap { Int($0) }, fields: fields.map(\.field),
                fieldMessages: Dictionary(fields.map { ($0.field, $0.message) }) { first, _ in first },
                resumesAt: decoded.resumesAt)
        }
        throw APIError(status: status, code: ._internal, message: "The server answered \(status).")
    }
}
