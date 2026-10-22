import Foundation
import CryptoKit

struct AuthSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case tokenType = "token_type"
    }

    init(accessToken: String, refreshToken: String, expiresAt: Date, tokenType: String = "bearer") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
        tokenType = try c.decodeIfPresent(String.self, forKey: .tokenType) ?? "bearer"
        if let seconds = try? c.decode(Double.self, forKey: .expiresAt) {
            expiresAt = Date(timeIntervalSince1970: seconds)
        } else {
            expiresAt = Date().addingTimeInterval(3600)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accessToken, forKey: .accessToken)
        try c.encode(refreshToken, forKey: .refreshToken)
        try c.encode(expiresAt.timeIntervalSince1970, forKey: .expiresAt)
        try c.encode(tokenType, forKey: .tokenType)
    }
}

struct AuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let expiresAt: Int?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case tokenType = "token_type"
    }

    var session: AuthSession {
        let expiration = expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? Date().addingTimeInterval(TimeInterval(expiresIn ?? 3600))
        return AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken ?? "",
            expiresAt: expiration,
            tokenType: tokenType ?? "bearer"
        )
    }
}

struct OperatorSessionResponse: Decodable {
    let ok: Bool
    let operatorSession: String
    let expiresAt: String
    let bootstrapped: Bool?
}

struct OperatorSession: Codable, Equatable {
    let token: String
    let expiresAt: Date
}

struct SolverQueueResponse: Decodable { var requests: [SolverRequest]; let unreadCounts: [String: Int]?; let nextOffset: Int? }
struct SolverDetailResponse: Decodable { let request: SolverRequest; var messages: [SolverMessage]; let nextOffset: Int? }

struct SolverRequest: Identifiable, Decodable, Hashable {
    let id: UUID
    var status: String
    var subject: String
    var stem: String
    var options: JSONValue?
    var choiceLabels: JSONValue?
    var sourceMetadata: JSONValue?
    var figureRefs: [SolverFigure]?
    /// New snapshot media is optional until the backend rollout; legacy requests still use figure_refs.
    var questionMedia: [SolverFigure]?
    var createdAt: Date?
    var claimedAt: Date?
    var answeredAt: Date?
    var lastStudentMessageAt: Date?
    var operatorReadAt: Date?
    var hasUnreadStudentMessage: Bool {
        guard let lastStudentMessageAt else { return false }
        return operatorReadAt.map { $0 < lastStudentMessageAt } ?? true
    }

    enum CodingKeys: String, CodingKey {
        case id, status, subject, stem, options
        case choiceLabels = "choice_labels"
        case sourceMetadata = "source_metadata"
        case figureRefs = "figure_refs"
        case questionMedia = "question_media"
        case createdAt = "created_at"
        case claimedAt = "claimed_at"
        case answeredAt = "answered_at"
        case lastStudentMessageAt = "last_student_message_at"
        case operatorReadAt = "operator_read_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        status = try c.decode(String.self, forKey: .status)
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        stem = try c.decode(String.self, forKey: .stem)
        options = try c.decodeIfPresent(JSONValue.self, forKey: .options)
        choiceLabels = try c.decodeIfPresent(JSONValue.self, forKey: .choiceLabels)
        sourceMetadata = try c.decodeIfPresent(JSONValue.self, forKey: .sourceMetadata)
        figureRefs = try c.decodeIfPresent([SolverFigure].self, forKey: .figureRefs)
        questionMedia = try c.decodeIfPresent([SolverFigure].self, forKey: .questionMedia)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        claimedAt = try c.decodeIfPresent(Date.self, forKey: .claimedAt)
        answeredAt = try c.decodeIfPresent(Date.self, forKey: .answeredAt)
        lastStudentMessageAt = try c.decodeIfPresent(Date.self, forKey: .lastStudentMessageAt)
        operatorReadAt = try c.decodeIfPresent(Date.self, forKey: .operatorReadAt)
    }

    var optionLines: [String] {
        guard let options else { return [] }
        switch options {
        case .array(let values):
            let labels: [String] = {
                guard case .array(let l)? = choiceLabels else { return [] }
                return l.compactMap(\.stringValue)
            }()
            return values.enumerated().map { index, value in
                let label = index < labels.count ? labels[index] : String(UnicodeScalar(65 + index)!)
                return "\(label). \(value.displayText)"
            }
        default: return []
        }
    }

    var displayMedia: [SolverFigure] {
        // Avoid rendering a newly supplied crop twice when figure_refs is also present
        // for backwards compatibility.
        if let questionMedia, !questionMedia.isEmpty { return questionMedia }
        return figureRefs ?? []
    }

    var sharedPassage: String? {
        guard case .object(let metadata)? = sourceMetadata,
              let value = metadata["shared_passage"]?.stringValue,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

struct SolverFigure: Decodable, Hashable, Identifiable {
    // Media identity must not change on every SwiftUI render.
    var id: String { "\(bucket ?? "")|\(path ?? "")|\(displayOrder ?? 0)" }
    let bucket: String?
    let path: String?
    let signedURL: String?
    let label: String?
    /// Optional on legacy figure_refs; the backend will populate it for new media.
    let kind: String?
    let displayOrder: Int?

    enum CodingKeys: String, CodingKey {
        case bucket, path, label, kind
        case signedURL
        case displayOrder = "display_order"
    }

    var isOriginalCrop: Bool {
        kind == "original_selected_crop" || kind == "stem_crop"
    }

    var isExtractedFigure: Bool {
        kind == "extracted_figure" || kind == "diagram" || kind == "chart"
    }
}

struct SolverMessage: Identifiable, Decodable, Hashable {
    let id: UUID
    let requestID: UUID
    let authorKind: String
    let body: String?
    let attachments: [SolverAttachment]?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, body, attachments
        case requestID = "request_id"
        case authorKind = "author_kind"
        case createdAt = "created_at"
    }
}

struct SolverAttachment: Codable, Hashable, Identifiable {
    var id: String { path }
    let bucket: String
    let path: String
    let mimeType: String
    let byteSize: Int
    let displayOrder: Int
    var signedURL: String?
}

struct UploadedAttachmentResponse: Decodable {
    let attachment: SolverAttachment
}

struct ReplyResponse: Decodable { let message: SolverMessage }

struct PendingImage: Identifiable, Hashable {
    let id: UUID
    let data: Data
    let previewData: Data?
    let filename: String
    let mimeType: String

    init(id: UUID = UUID(), data: Data, previewData: Data? = nil, filename: String, mimeType: String) {
        self.id = id
        self.data = data
        self.previewData = previewData
        self.filename = filename
        self.mimeType = mimeType
    }
}

indirect enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var displayText: String {
        switch self {
        case .string(let v): return v
        case .number(let v): return v.rounded() == v ? String(Int(v)) : String(v)
        case .bool(let v): return v ? "true" : "false"
        case .array(let v): return v.map(\.displayText).joined(separator: " / ")
        case .object(let v): return v.map { "\($0.key): \($0.value.displayText)" }.joined(separator: ", ")
        case .null: return ""
        }
    }
}

struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encodeImpl = value.encode }
    func encode(to encoder: Encoder) throws { try encodeImpl(encoder) }
}

struct SolverReplyIdentity {
    static func key(ownerID: String, requestID: UUID, text: String, images: [Data]) throws -> String {
        let values = [ownerID, requestID.uuidString, text] + images.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let data = try JSONEncoder().encode(values)
        return "solver.pending-reply." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func clientUID(key: String, defaults: UserDefaults = .standard) -> String {
        let uid = defaults.string(forKey: key) ?? "reply-" + UUID().uuidString.lowercased()
        defaults.set(uid, forKey: key)
        return uid
    }
}
