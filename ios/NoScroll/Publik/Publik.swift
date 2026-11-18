// Publik.swift — Sign in with publik, usage counting, and publik API as one provider option.
import Foundation
import UIKit

protocol PublikGateUI: Sendable {
    func show(_ screen: Publik.Screen) async -> String?
    func open(_ url: URL)
}

enum Publik {
    static let appSlug = "noscroll"
    static let appName = (Bundle.main.object(forInfoDictionaryKey: "AppFullName") as? String)
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "This app"
    static let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    static let usesAI = false

    enum GateMode: String { case required, optional }
    static let gateMode: GateMode = .optional

    static var deleteAccountURL: URL { PublikLinks.deleteAccountURL(origin: origin) ?? publikDeleteAccountURL }
    private static let publikDeleteAccountURL = URL(string: "https://publikhq.com/in-app/delete-account")!
    static var privacyURL: URL { PublikLinks.privacyURL(origin: origin) ?? publikPrivacyURL }
    private static let publikPrivacyURL = URL(string: "https://publikhq.com/in-app/privacy")!
    static var supportURL: URL { PublikLinks.supportURL(origin: origin) ?? publikSupportURL }
    private static let publikSupportURL = URL(string: "https://publikhq.com/in-app/support")!

    static func hook(_ name: String) -> String? {
        #if PUBLIK_TEST_HOOKS
        let raw = ProcessInfo.processInfo.environment[name] ?? UserDefaults.standard.string(forKey: name)
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
        #else
        return nil
        #endif
    }

    static func hookURL(_ name: String) -> String? {
        guard var value = hook(name) else { return nil }
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return value
    }

    static let testBaseURL: String? = hookURL("PUBLIK_API_BASE_URL")
    static let origin: String = {
        if let base = testBaseURL { return base.hasSuffix("/api/v1") ? String(base.dropLast("/api/v1".count)) : base }
        return hookURL("PUBLIK_ORIGIN") ?? "https://publikhq.com"
    }()
    static let defaultBaseURL = "\(origin)/api/v1"
    static let models = (fast: "publik-fast", balanced: "publik-balanced", smart: "publik-smart")

    struct Credential: Codable { var key: String; var base_url: String; var install_id: String; var claim_url: String?; var choice: String?; var claimed: Bool?; var handle: String?; var email: String? }
    struct Wallet: Sendable { var claimed: Bool; var claimURL: String?; var handle: String?; var email: String? = nil; var planKind: String; var planLabel: String?; var balanceMicros: Int; var topUpURL: String }
    struct Screen: Sendable { let id: String; let title: String; let body: String; let note: String?; let buttons: [(action: String, label: String)] }
    enum Provider { case own(baseURL: String, apiKey: String), publik(baseURL: String, apiKey: String), needsOwnKey }
    struct PublikError: LocalizedError { let message: String; var errorDescription: String? { message } }

    static var appToken: String {
        if let hooked = hook("PUBLIK_APP_TOKEN") { return hooked }
        guard let url = Bundle.main.url(forResource: "publik-app-token", withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    #if arch(arm64)
    static let arch: String? = "arm64"
    #elseif arch(x86_64)
    static let arch: String? = "x64"
    #else
    static let arch: String? = nil
    #endif

    static var publikDir: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("publik") }
    static var credentialURL: URL { publikDir.appendingPathComponent("apps/\(appSlug).json") }

    static func readCredential() -> Credential? {
        guard let data = try? Data(contentsOf: credentialURL), let c = try? JSONDecoder().decode(Credential.self, from: data), c.key.hasPrefix("pk_") else { return nil }
        return c
    }

    private static func write(_ c: Credential?) throws {
        try FileManager.default.createDirectory(at: credentialURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        excludeFromBackup(publikDir)
        try (c.map { try JSONEncoder().encode($0) } ?? Data("{}".utf8)).write(to: credentialURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialURL.path)
        excludeFromBackup(credentialURL)
    }

    private static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    static func setChoice(_ choice: String?) { if var c = readCredential() { c.choice = choice; try? write(c) } }

    static func resolveProvider(userKey: (baseURL: String, apiKey: String)?) -> Provider {
        if let key = hook("PUBLIK_API_KEY") { return .publik(baseURL: defaultBaseURL, apiKey: key) }
        if let c = readCredential(), c.choice == "publik" { return .publik(baseURL: c.base_url, apiKey: c.key) }
        if let u = userKey, !u.apiKey.isEmpty { return .own(baseURL: u.baseURL, apiKey: u.apiKey) }
        return .needsOwnKey
    }

    private static func request(_ method: String, _ url: String, body: [String: Any]? = nil, key: String? = nil, timeout: TimeInterval = 20) async throws -> (Int, [String: Any]) {
        let (status, json) = try await requestJSON(method, url, body: body, key: key, timeout: timeout)
        return (status, json ?? [:])
    }

    private static func requestJSON(_ method: String, _ url: String, body: [String: Any]? = nil, key: String? = nil, timeout: TimeInterval = 20) async throws -> (Int, [String: Any]?) {
        guard let target = URL(string: url) else { throw PublikError(message: "publik address is not valid.") }
        var req = URLRequest(url: target, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    static func provision() async throws -> Credential {
        let token = appToken
        guard token.hasPrefix("pat_") else { throw PublikError(message: "This build has no publik app token. Ask the developer for a new build.") }
        let prior = readCredential()
        var installID = prior?.install_id ?? UUID().uuidString.lowercased()
        let deviceName = await MainActor.run { UIDevice.current.name }
        for _ in 0..<2 {
            var fields: [String: Any] = ["app_token": token, "app_slug": appSlug, "app_version": appVersion, "os": "ios", "install_id": installID,
                                         "device_name": String(deviceName.prefix(120)), "disclosure_version": 1, "dialects": ["chat_completions"]]
            if let arch { fields["arch"] = arch }
            let (status, body) = try await request("POST", "\(origin)/api/v1/installs", body: fields)
            let error = body["error"] as? [String: Any]
            if status == 200 || status == 201, let key = (body["key"] as? String) ?? (status == 200 ? prior?.key : nil) {
                let c = Credential(key: key, base_url: body["base_url"] as? String ?? defaultBaseURL, install_id: body["install_id"] as? String ?? installID,
                                   claim_url: body["claim_url"] as? String, choice: prior?.choice)
                try write(c)
                return c
            }
            if status == 200 || error?["type"] as? String == "install_revoked" { installID = UUID().uuidString.lowercased(); continue }
            throw PublikError(message: error?["message"] as? String ?? "publik could not set up this device (\(status)).")
        }
        throw PublikError(message: "publik could not set up this device.")
    }

    static func readWallet(_ key: String) async throws -> (Int, Wallet?, String?) {
        let a = try await walletAnswer(key)
        return (a.status, a.wallet, a.message)
    }

    static func walletAnswer(_ key: String, timeout: TimeInterval = 15) async throws -> (status: Int, wallet: Wallet?, message: String?, json: Bool) {
        let (status, json) = try await requestJSON("GET", "\(origin)/api/v1/wallet", key: key, timeout: timeout)
        let b = json ?? [:]
        guard status == 200, let state = b["claim_state"] as? String else { return (status, nil, (b["error"] as? [String: Any])?["message"] as? String, json != nil) }
        let plan = b["plan"] as? [String: Any]
        let account = b["account"] as? [String: Any]
        let email = ((account?["email"] as? String) ?? (b["email"] as? String)).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.contains("@") ? $0 : nil }
        return (status, Wallet(claimed: state == "claimed", claimURL: b["claim_url"] as? String, handle: account?["handle"] as? String, email: email,
                               planKind: plan?["kind"] as? String ?? "none", planLabel: plan?["label"] as? String, balanceMicros: b["balance_micros"] as? Int ?? 0,
                               topUpURL: b["top_up_url"] as? String ?? "\(origin)/wallet"), nil, true)
    }

    static func gateScreen(_ id: String, _ w: Wallet? = nil, note: String? = nil, message: String? = nil) -> Screen {
        if id == "unreachable" { return Screen(id: id, title: "Sign in with publik", body: message ?? "publik is not reachable. Check your connection.", note: note, buttons: [("retry", "Retry")]) }
        if id == "sign_in" {
            return Screen(id: id, title: "Sign in with publik", body: "\(appName) uses your publik account. Tap Sign in with publik and sign in on the publik page. The page then closes, and \(appName) opens by itself.",
                          note: note, buttons: [("sign_in", "Sign in with publik")])
        }
        let who = w?.handle.map { "You are signed in as @\($0)." } ?? "You are signed in to publik."
        guard let w, w.planKind != "none" || w.balanceMicros > 0 else {
            return Screen(id: id, title: "Choose how to pay for AI", body: "\(who) This app uses AI. Get a publik plan, or use your own key.", note: note,
                          buttons: [("get_plan", "Get a plan"), ("own_key", "Use my own key")])
        }
        let what = w.planKind == "plan" ? "Your plan: \(w.planLabel ?? "publik")." : String(format: "Your balance: $%.2f.", Double(w.balanceMicros) / 1_000_000)
        return Screen(id: id, title: "Connect your plan", body: "\(who) \(what) Connect it to use AI in this app, or use your own key.", note: note,
                      buttons: [("connect", "Connect your plan"), ("own_key", "Use my own key")])
    }

    static func pollNow() { NotificationCenter.default.post(name: pollNowNotification, object: nil) }
    private static let pollNowNotification = Notification.Name("publik.pollNow")

    static func ensureSignedIn(_ ui: PublikGateUI) async -> (key: String, wallet: Wallet, choice: String?)? {
        let w = Wallet(claimed: true, claimURL: nil, handle: "local", email: nil, planKind: "none", planLabel: nil, balanceMicros: 0, topUpURL: "https://publikhq.com/wallet")
        return ("pk_local", w, nil)
    }

    static func resume() async -> Wallet? {
        return nil
    }

    @MainActor static func signOut() {
        stopTelemetry()
        let key = readCredential()?.key
        try? FileManager.default.removeItem(at: credentialURL)
        guard let key else { return }
        let url = "\(origin)/api/v1/installs/revoke"
        Task.detached(priority: .utility) { _ = try? await request("POST", url, key: key, timeout: 10) }
    }

    @MainActor static func deleteLocalData() {
        signOut()
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: publikDir, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent != "consent.json" {
            try? fm.removeItem(at: url)
        }
        resetTelemetryInstallID()
    }

    static func selfTestIfAsked() async {
        if hook("PUBLIK_SELF_TEST") != nil { print(await selfTest()); exit(0) }
    }

    static func selfTest() async -> String {
        do {
            let (status, w, message) = try await readWallet(try await provision().key)
            guard w != nil else { throw PublikError(message: message ?? "GET /wallet answered \(status)") }
            return "publik self-test: ok \(appSlug) \(appVersion)"
        } catch is URLError { return "publik self-test: failed: publik is not reachable. Check your connection." }
        catch { return "publik self-test: failed: \(error.localizedDescription)" }
    }

    @MainActor private static var telemetryTask: Task<Void, Never>?

    static var usageConsent: Bool {
        get {
            guard let data = try? Data(contentsOf: publikDir.appendingPathComponent("consent.json")),
                  let consent = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return true }
            return consent["usage"] as? Bool != false
        }
        set {
            try? FileManager.default.createDirectory(at: publikDir, withIntermediateDirectories: true)
            try? Data("{\"usage\":\(newValue)}\n".utf8).write(to: publikDir.appendingPathComponent("consent.json"), options: .atomic)
        }
    }

    private static func usageOff() -> Bool {
        let env = ProcessInfo.processInfo.environment
        let dnt = (env["DO_NOT_TRACK"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if !["", "0", "false"].contains(dnt) || ["0", "false", "off"].contains((env["PUBLIK_TELEMETRY"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()) { return true }
        guard let data = try? Data(contentsOf: publikDir.appendingPathComponent("consent.json")),
              let consent = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return consent["usage"] as? Bool == false
    }

    private static let telemetryIDLock = NSLock()
    nonisolated(unsafe) private static var cachedTelemetryID: String?

    private static func telemetryInstallID() -> String {
        telemetryIDLock.lock()
        defer { telemetryIDLock.unlock() }
        if let id = cachedTelemetryID { return id }
        let id = loadOrCreateTelemetryID()
        cachedTelemetryID = id
        return id
    }

    static func resetTelemetryInstallID() {
        telemetryIDLock.lock()
        cachedTelemetryID = nil
        telemetryIDLock.unlock()
    }

    private static func loadOrCreateTelemetryID() -> String {
        let file = publikDir.appendingPathComponent("telemetry.json")
        func saved() -> String? {
            guard let data = try? Data(contentsOf: file), let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["install_id"] as? String,
                  let uuid = UUID(uuidString: id), id.count == 36, Array(id)[14] == "4" else { return nil }
            return uuid.uuidString.lowercased()
        }
        if let id = saved() { return id }
        let fresh = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: publikDir, withIntermediateDirectories: true)
        excludeFromBackup(publikDir)
        let created = ISO8601DateFormatter().string(from: Date())
        let text = Data("{\"install_id\":\"\(fresh)\",\"created_at\":\"\(created)\"}\n".utf8)
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return saved() ?? fresh }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        h.write(text); try? h.close()
        return fresh
    }

    private static func sendEvent(_ event: String) async {
        let debug = hook("PUBLIK_TELEMETRY_DEBUG") == "1"
        func say(_ result: String) { if debug { FileHandle.standardError.write(Data("publik-telemetry: \(event) -> \(result)\n".utf8)) } }
        if usageOff() { return say("off (opt-out)") }
        let key = hook("PUBLIK_API_KEY") ?? readCredential()?.key
        var body: [String: Any] = ["v": 1, "app": appSlug, "install_id": telemetryInstallID(), "event": event, "app_version": appVersion.hasPrefix("v") ? String(appVersion.dropFirst()) : appVersion, "os": "ios"]
        if let arch { body["arch"] = arch }
        do { say(String(try await request("POST", hookURL("PUBLIK_TELEMETRY_URL") ?? "\(origin)/api/v1/telemetry", body: body, key: key?.hasPrefix("pk_") == true ? key : nil, timeout: 5).0)) }
        catch { say((error as? URLError).map { "\($0.code.rawValue)" } ?? "error") }
    }

    @MainActor static func startTelemetry() {
        if telemetryTask != nil { return }
        let s = Double(hook("PUBLIK_TELEMETRY_INTERVAL_SECONDS") ?? "") ?? 0
        let interval = (1...86_400).contains(s) ? s : 1_800
        telemetryTask = Task.detached(priority: .background) {
            await sendEvent("app_opened")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                await sendEvent("active_session")
            }
        }
    }

    @MainActor static func stopTelemetry() {
        telemetryTask?.cancel()
        telemetryTask = nil
    }

    static func topUpURLFrom402(_ data: Data) -> (message: String, url: URL?) {
        let e = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? [String: Any]
        return (e?["message"] as? String ?? "Not enough publik API balance.", (e?["top_up_url"] as? String).flatMap(URL.init(string:)))
    }

    static func search(baseURL: String, apiKey: String, q: String, count: Int = 10) async throws -> (results: [[String: Any]], message: String?, url: URL?) {
        let (status, body) = try await request("POST", "\(baseURL)/search", body: ["q": q, "count": count], key: apiKey, timeout: 30)
        if status == 402 { let t = topUpURLFrom402((try? JSONSerialization.data(withJSONObject: body)) ?? Data()); return ([], t.message, t.url) }
        guard status == 200 else { throw PublikError(message: "publik API answered \(status).") }
        return (body["results"] as? [[String: Any]] ?? [], nil, nil)
    }
}
