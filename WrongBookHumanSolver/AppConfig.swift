import Foundation

enum AppConfig {
    static let supabaseURL = URL(string: "https://rfpkznuntzxfoeeavwwf.supabase.co")!
    static let publishableKey = "sb_publishable_Nt8ik0KBWLdi8hucG9oDRQ_cnMyQ9Gx"
    static let adminFunctionURL = supabaseURL.appendingPathComponent("functions/v1/wrongbook-human-solver-admin")
    static let oauthCallback = URL(string: "wrongbooksolver://auth/callback")!
}
