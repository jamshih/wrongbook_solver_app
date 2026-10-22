import Foundation
import UIKit

final class HumanSolverAdminAPI {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .useDefaultKeys
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let raw = try c.decode(String.self)
            if let date = ISO8601DateFormatter.fractional.date(from: raw) ?? ISO8601DateFormatter.standard.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO date")
        }
        return d
    }()

    private let auth: AuthStore
    init(auth: AuthStore) { self.auth = auth }

    func queue(status: String) async throws -> [SolverRequest] {
        let data = try await call(["action": AnyEncodable("queue"), "status": AnyEncodable(status)], timeout: 10)
        return try Self.decoder.decode(SolverQueueResponse.self, from: data).requests
    }

    func detail(id: UUID) async throws -> SolverDetailResponse {
        let data = try await call(["action": AnyEncodable("detail"), "requestID": AnyEncodable(id.uuidString)], timeout: 10)
        return try Self.decoder.decode(SolverDetailResponse.self, from: data)
    }

    func claim(id: UUID) async throws {
        _ = try await call(["action": AnyEncodable("claim"), "requestID": AnyEncodable(id.uuidString)], timeout: 12)
    }

    func close(id: UUID) async throws {
        _ = try await call(["action": AnyEncodable("close"), "requestID": AnyEncodable(id.uuidString)], timeout: 12)
    }

    func revokeOtherSessions() async throws -> Int {
        let data = try await call(["action": AnyEncodable("revoke_sessions")])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["revoked"] as? Int ?? 0
    }

    func rotateOperatorKey(to newKey: String) async throws -> Int {
        let data = try await call(["action": AnyEncodable("rotate_key"), "newOperatorKey": AnyEncodable(newKey)])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["keyVersion"] as? Int ?? 0
    }

    func upload(_ image: PendingImage, requestID: UUID, displayOrder: Int) async throws -> SolverAttachment {
        let body: [String: AnyEncodable] = [
            "action": AnyEncodable("upload"), "requestID": AnyEncodable(requestID.uuidString),
            "uploadUID": AnyEncodable("ios_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"),
            "mimeType": AnyEncodable(image.mimeType), "fileName": AnyEncodable(image.filename),
            "displayOrder": AnyEncodable(displayOrder), "base64": AnyEncodable(image.data.base64EncodedString())
        ]
        let data = try await call(body, timeout: 90)
        return try Self.decoder.decode(UploadedAttachmentResponse.self, from: data).attachment
    }

    func reply(requestID: UUID, text: String, images: [PendingImage]) async throws -> SolverMessage {
        var attachments: [SolverAttachment] = []
        for (index, image) in images.enumerated() { attachments.append(try await upload(image, requestID: requestID, displayOrder: index)) }
        let body: [String: AnyEncodable] = [
            "action": AnyEncodable("reply"), "requestID": AnyEncodable(requestID.uuidString),
            "clientUID": AnyEncodable("ios_reply_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"),
            "text": AnyEncodable(text), "attachments": AnyEncodable(attachments)
        ]
        let data = try await call(body, timeout: 90)
        return try Self.decoder.decode(ReplyResponse.self, from: data).message
    }

    private func call(_ body: [String: AnyEncodable], timeout: TimeInterval = 12) async throws -> Data {
        let access = try await auth.validAccessToken()
        // AuthStore is @MainActor. operatorToken() is synchronous, so unlike
        // validAccessToken() it cannot be crossed with a bare `await` from this
        // nonisolated API object. Read it explicitly on MainActor, then perform
        // the network request outside MainActor.
        let operatorToken = try await MainActor.run {
            try auth.operatorToken()
        }
        do { return try await Self.rawRequest(accessToken: access, operatorToken: operatorToken, body: body, timeout: timeout) }
        catch let e as AppError {
            if e.errorDescription == "operator_forbidden" { await MainActor.run { auth.lockOperator() } }
            throw e
        }
    }

    static func rawRequest(accessToken: String, operatorToken: String?, body: [String: AnyEncodable], timeout: TimeInterval = 12) async throws -> Data {
        var req = URLRequest(url: AppConfig.adminFunctionURL)
        req.httpMethod = "POST"; req.timeoutInterval = timeout
        req.setValue(AppConfig.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let operatorToken { req.setValue(operatorToken, forHTTPHeaderField: "x-wb-operator-session") }
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await NetworkTransport.data(for: req, timeout: timeout)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw AppError.from(data: data) }
        return data
    }
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    static let standard: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
}

extension JSONDecoder.DateDecodingStrategy {
    func date(_ value: String) -> Date? { ISO8601DateFormatter.fractional.date(from: value) ?? ISO8601DateFormatter.standard.date(from: value) }
}

extension JSONDecoder {
    func dateDecodingStrategyDate(_ value: String) -> Date? { ISO8601DateFormatter.fractional.date(from: value) ?? ISO8601DateFormatter.standard.date(from: value) }
}

/// Dedicated transport for the private native operator app.
///
/// V175 relied on URLRequest/URLSession timeout properties. Those are useful, but they are not a
/// strict wall-clock deadline for every phase of connection establishment. A broken DNS/socket path
/// could therefore keep the first queue request visibly spinning for much longer than intended.
/// V177 races the real request against an explicit Task.sleep watchdog. The losing child is cancelled.
enum NetworkTransport {
    private struct TransportResponse: @unchecked Sendable {
        let data: Data
        let response: URLResponse
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func data(for request: URLRequest, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        var bounded = request
        let hardTimeout = min(max(timeout, 3), 90)
        bounded.timeoutInterval = hardTimeout
        let finalRequest = bounded

        do {
            return try await withThrowingTaskGroup(of: TransportResponse.self) { group in
                group.addTask {
                    let (data, response) = try await session.data(for: finalRequest)
                    try Task.checkCancellation()
                    return TransportResponse(data: data, response: response)
                }

                group.addTask {
                    let nanoseconds = UInt64(hardTimeout * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanoseconds)
                    throw URLError(.timedOut)
                }

                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw URLError(.cancelled)
                }
                return (first.data, first.response)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppError.from(error)
        }
    }
}
