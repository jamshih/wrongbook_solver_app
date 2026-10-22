import AuthenticationServices
import Foundation
import UIKit

@MainActor
final class AuthStore: ObservableObject {
    enum State: Equatable { case signedOut, signedIn, operatorReady, busy(String), error(String) }

    @Published var state: State = .signedOut
    @Published var operatorKey = ""
    @Published var email = ""
    @Published var password = ""

    private(set) var authSession: AuthSession?
    private(set) var operatorSession: OperatorSession?
    private var oauthCoordinator: OAuthCoordinator?
    private var operationGeneration = 0

    private let authAccount = "supabase-auth-session"
    private let operatorAccount = "operator-session"

    init() { restore() }

    func restore() {
        let decoder = JSONDecoder()
        if let d = KeychainStore.get(account: authAccount), let s = try? decoder.decode(AuthSession.self, from: d) { authSession = s }
        if let d = KeychainStore.get(account: operatorAccount), let s = try? decoder.decode(OperatorSession.self, from: d), s.expiresAt > Date() { operatorSession = s }
        if authSession != nil && operatorSession != nil { state = .operatorReady }
        else if authSession != nil { state = .signedIn }
        else { state = .signedOut }
    }

    func signInPassword() async {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty, !password.isEmpty else { state = .error("請輸入 Email 和密碼。") ; return }
        let operation = beginOperation("登入中…")
        do {
            let payload = ["email": e, "password": password]
            let data = try await requestAuth(path: "/auth/v1/token?grant_type=password", body: payload)
            let response = try JSONDecoder().decode(AuthTokenResponse.self, from: data)
            guard operation == operationGeneration else { return }
            try saveAuth(response.session)
            password = ""
            state = .signedIn
        } catch {
            guard operation == operationGeneration else { return }
            state = .error(AppError.userFacingMessage(for: error))
        }
    }

    func signInGoogle() async {
        let operation = beginOperation("開啟 Google 登入…")
        do {
            var components = URLComponents(url: AppConfig.supabaseURL.appendingPathComponent("auth/v1/authorize"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                .init(name: "provider", value: "google"),
                .init(name: "redirect_to", value: AppConfig.oauthCallback.absoluteString),
                .init(name: "scopes", value: "openid email profile")
            ]
            guard let url = components.url, let anchor = Self.presentationAnchor() else { throw AppError.message("無法開啟登入視窗。") }
            let coordinator = OAuthCoordinator(anchor: anchor)
            oauthCoordinator = coordinator
            defer { oauthCoordinator = nil }
            let callback = try await coordinator.authenticate(url: url, callbackScheme: AppConfig.oauthCallback.scheme ?? "wrongbooksolver")
            guard operation == operationGeneration else { return }
            let params = Self.callbackParameters(callback)
            if let error = params["error"] { throw AppError.message(params["error_description"] ?? error) }
            guard let access = params["access_token"], !access.isEmpty else { throw AppError.message("Google 登入完成，但沒有收到 Supabase session。請確認 Supabase Redirect URLs 已加入 wrongbooksolver://auth/callback。") }
            let expiresIn = TimeInterval(Int(params["expires_in"] ?? "") ?? 3600)
            let session = AuthSession(accessToken: access, refreshToken: params["refresh_token"] ?? "", expiresAt: Date().addingTimeInterval(expiresIn), tokenType: params["token_type"] ?? "bearer")
            try saveAuth(session)
            state = .signedIn
        } catch {
            guard operation == operationGeneration else { return }
            if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { restore() }
            else { state = .error(AppError.userFacingMessage(for: error)) }
        }
    }

    func unlockOperator() async {
        guard operatorKey.count >= 30 else { state = .error("請輸入真人解題 Operator Key。") ; return }
        let operation = beginOperation("驗證擁有者…")
        do {
            let access = try await validAccessToken()
            let body: [String: AnyEncodable] = ["action": AnyEncodable("operator_session"), "operatorKey": AnyEncodable(operatorKey)]
            let data = try await HumanSolverAdminAPI.rawRequest(accessToken: access, operatorToken: nil, body: body, timeout: 10)
            let r = try HumanSolverAdminAPI.decoder.decode(OperatorSessionResponse.self, from: data)
            guard operation == operationGeneration else { return }
            guard r.ok else { throw AppError.message("Operator 驗證失敗。") }
            let expiry = HumanSolverAdminAPI.decoder.dateDecodingStrategyDate(r.expiresAt) ?? Date().addingTimeInterval(12 * 3600)
            let s = OperatorSession(token: r.operatorSession, expiresAt: expiry)
            try KeychainStore.set(JSONEncoder().encode(s), account: operatorAccount)
            operatorSession = s
            operatorKey = ""
            state = .operatorReady
        } catch {
            guard operation == operationGeneration else { return }
            state = .error(AppError.userFacingMessage(for: error))
        }
    }

    func cancelBusyOperation() {
        operationGeneration += 1
        oauthCoordinator?.cancel()
        oauthCoordinator = nil
        restore()
    }

    private func beginOperation(_ label: String) -> Int {
        operationGeneration += 1
        state = .busy(label)
        return operationGeneration
    }

    func validAccessToken() async throws -> String {
        guard var session = authSession else { throw AppError.message("請先登入。") }
        if session.expiresAt.timeIntervalSinceNow > 60 { return session.accessToken }
        guard !session.refreshToken.isEmpty else { signOut(); throw AppError.message("登入已過期，請重新登入。") }
        do {
            let data = try await requestAuth(path: "/auth/v1/token?grant_type=refresh_token", body: ["refresh_token": session.refreshToken])
            let response = try JSONDecoder().decode(AuthTokenResponse.self, from: data)
            session = response.session
            if session.refreshToken.isEmpty { session.refreshToken = authSession?.refreshToken ?? "" }
            try saveAuth(session)
            return session.accessToken
        } catch {
            // A temporary DNS/offline/connection failure must not erase a valid stored login.
            // V174 signed the operator out for every refresh error, which amplified transient
            // network failures and made launch recovery much harder.
            if AppError.isTransientNetwork(error) { throw error }
            signOut()
            throw AppError.message("登入已失效，請重新登入。")
        }
    }

    func operatorToken() throws -> String {
        guard let s = operatorSession, s.expiresAt > Date() else {
            operatorSession = nil
            try? KeychainStore.set(nil, account: operatorAccount)
            state = authSession == nil ? .signedOut : .signedIn
            throw AppError.message("Operator session 已過期，請重新輸入 Key。")
        }
        return s.token
    }

    func signOut() {
        authSession = nil; operatorSession = nil; password = ""; operatorKey = ""
        try? KeychainStore.set(nil, account: authAccount)
        try? KeychainStore.set(nil, account: operatorAccount)
        state = .signedOut
    }

    func lockOperator() {
        operatorSession = nil
        try? KeychainStore.set(nil, account: operatorAccount)
        state = authSession == nil ? .signedOut : .signedIn
    }

    private func saveAuth(_ session: AuthSession) throws {
        authSession = session
        try KeychainStore.set(JSONEncoder().encode(session), account: authAccount)
    }

    private func requestAuth<T: Encodable>(path: String, body: T) async throws -> Data {
        var req = URLRequest(url: URL(string: path, relativeTo: AppConfig.supabaseURL)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue(AppConfig.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await NetworkTransport.data(for: req, timeout: 10)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw AppError.from(data: data) }
        return data
    }

    private static func callbackParameters(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for raw in [URLComponents(url: url, resolvingAgainstBaseURL: false)?.query, url.fragment].compactMap({ $0 }) {
            for pair in raw.split(separator: "&") {
                let p = pair.split(separator: "=", maxSplits: 1).map(String.init)
                let key = p[0].removingPercentEncoding ?? p[0]
                let value = (p.count > 1 ? p[1] : "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
                out[key] = value
            }
        }
        return out
    }

    private static func presentationAnchor() -> ASPresentationAnchor? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
    }
}

private final class OAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    private var session: ASWebAuthenticationSession?
    init(anchor: ASPresentationAnchor) { self.anchor = anchor }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
    func cancel() { session?.cancel(); session = nil }
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callback, error in
                self?.session = nil
                if let callback { continuation.resume(returning: callback) }
                else if let error { continuation.resume(throwing: error) }
                else { continuation.resume(throwing: AppError.message("登入沒有回傳結果。")) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            if !s.start() { session = nil; continuation.resume(throwing: AppError.message("無法啟動登入流程。")) }
        }
    }
}

enum AppError: LocalizedError {
    case message(String)
    case network(URLError.Code)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .network(let code): return Self.networkMessage(code)
        }
    }

    static func from(data: Data) -> AppError {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let e = obj["error_description"] as? String ?? obj["msg"] as? String ?? obj["error"] as? String {
            return .message(e)
        }
        return .message("伺服器要求失敗。")
    }

    static func from(_ error: Error) -> AppError {
        if let app = error as? AppError { return app }
        if let url = error as? URLError { return .network(url.code) }
        return .message(error.localizedDescription)
    }

    static func isTransientNetwork(_ error: Error) -> Bool {
        if let app = error as? AppError, case .network = app { return true }
        return error is URLError
    }

    static func userFacingMessage(for error: Error) -> String {
        from(error).localizedDescription
    }

    private static func networkMessage(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut:
            return "連線逾時。畫面不會被鎖住，請確認網路後再按一次重新整理。"
        case .notConnectedToInternet:
            return "目前沒有網路連線。你仍可操作畫面，恢復連線後再重新整理。"
        case .cannotFindHost, .dnsLookupFailed:
            return "目前無法找到 WrongBook 伺服器。請檢查網路或 DNS 後重試。"
        case .cannotConnectToHost, .networkConnectionLost:
            return "目前無法連到 WrongBook 伺服器。請稍後重新整理。"
        case .cancelled:
            return "連線已取消。"
        default:
            return "網路連線失敗（\(code.rawValue)）。請重試。"
        }
    }
}
