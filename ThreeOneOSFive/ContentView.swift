import SwiftUI
import UIKit
import AVKit
import AVFoundation
#if os(macOS)
import AppKit
#endif

// MARK: - 1. API & Auth Manager
// MARK: - KeyAuthManager
// API: GET https://appfluxcore.site/api/fluxcore_check.php?key=<KEY>
// Response: { "valid": bool, "expires_at": string, "app_name": string }
// MARK: - KeyAuthManager
// API: GET https://appfluxcore.site/api/fluxcore_check.php?key=<KEY>
// Response: { valid, expires_at, app_name, lifetime, note, message }
// Mirrors checkkey.html exactly.
class KeyAuthManager: ObservableObject {
    // ── Persistent storage ──────────────────────────────────────────────
    @AppStorage("saved_key")            var savedKey:           String = ""
    @AppStorage("key_name")             var keyName:            String = ""
    @AppStorage("key_duration")         var keyDuration:        String = ""
    @AppStorage("key_expiry")           var keyExpiry:          String = ""
    @AppStorage("key_note")             var keyNote:            String = ""
    @AppStorage("key_lifetime")         var keyLifetime:        Bool   = false
    @AppStorage("key_expiry_timestamp") var keyExpiryTimestamp: Double = 0
    /// UID của máy — bind vĩnh viễn qua DeviceUID (Keychain). Không xoá khi logout.
    @AppStorage("bound_device_uid")     var boundDeviceUID:     String = ""

    // ── Runtime state ───────────────────────────────────────────────────
    @Published var isAuthorized:              Bool   = false
    // Khởi động false: nếu không có savedKey thì không có gì để kiểm tra.
    // canAutoLogin=true → onAppear gọi verifyKey() → set true ngay lập tức.
    // Tránh spinner vô tận khi user chưa nhập key lần đầu.
    @Published var isAuthenticating:          Bool   = false
    @Published var errorMessage:              String? = nil
    @Published var isMaintenanceMode:         Bool   = false
    @Published var isPatchVisible:            Bool   = true
    @Published var isExitingApp:              Bool   = false
    @Published var isActivationTransitioning: Bool   = false
    /// Trạng thái patch toggle từ web dashboard (wedproxy). Poll mỗi 10 giây.
    @Published private(set) var webPatchEnabled: Bool = true
    /// Tập patch_id bị tắt riêng lẻ qua web/user wedproxy dashboard.
    /// Persist qua UserDefaults để restart app không re-fire disable notifications
    /// cho những patch vốn đã bị tắt từ trước (tránh double-restore).
    @Published private(set) var webDisabledPatchIDs: Set<String> = {
        let saved = UserDefaults.standard.stringArray(forKey: "fluxcore.webDisabledPatchIDs.persisted") ?? []
        return Set(saved)
    }()

    @Published private(set) var patchRemainingSeconds: TimeInterval?
    @Published private(set) var patchAccessWarning:    String?

    private var verificationTask:       URLSessionDataTask?
    private var verificationSession:    URLSession?
    private var verificationGeneration: UInt64 = 0
    private var patchPolicyTask:        Task<Void, Never>?
    private var runtimeStatusTask:      Task<Void, Never>?
    private var webPatchPollTask:       Task<Void, Never>?

    // ── Obfuscated endpoint (XOR 0x5A) ─────────────────────────────────
    // Decoded: https://appfluxcore.site/api/fluxcore_check.php?key=
    private var apiBaseURL: String {
        let b: [UInt8] = [0x32, 0x2e, 0x2e, 0x2a, 0x29, 0x60, 0x75, 0x75, 0x3b, 0x2a, 0x2a, 0x3c, 0x36, 0x2f, 0x22, 0x39, 0x35, 0x28, 0x3f, 0x74, 0x29, 0x33, 0x2e, 0x3f, 0x75, 0x3b, 0x2a, 0x33, 0x75, 0x3c, 0x36, 0x2f, 0x22, 0x39, 0x35, 0x28, 0x3f, 0x5, 0x39, 0x32, 0x3f, 0x39, 0x31, 0x74, 0x2a, 0x32, 0x2a, 0x65, 0x31, 0x3f, 0x23, 0x67]
        return String(bytes: b.map { $0 ^ 0x5A }, encoding: .utf8) ?? ""
    }

    // Decoded: https://appfluxcore.site/api/wedproxy_state.php?key=
    private var wedProxyBaseURL: String {
        let b: [UInt8] = [0x32,0x2e,0x2e,0x2a,0x29,0x60,0x75,0x75,0x3b,0x2e,0x2a,0x3c,0x36,0x2f,
                          0x22,0x39,0x35,0x28,0x3f,0x74,0x27,0x2a,0x3b,0x2a,0x75,0x27,0x3b,0x2f,
                          0x3d,0x3e,0x74,0x29,0x2e,0x3b,0x2e,0x75,0x2a,0x32,0x2e,0x23,0x67]
        return String(bytes: b.map { $0 ^ 0x5A }, encoding: .utf8) ?? ""
    }

    private func endpoint(for key: String) -> URL? {
        let uid  = DeviceUID.current
        let safe = key.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_"))) ?? key
        let uidSafe = uid.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-"))) ?? uid
        return URL(string: apiBaseURL + safe + "&device_id=" + uidSafe)
    }

    // ── Format date string — mirrors fmtDate() in HTML ─────────────────
    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let normalized = raw.replacingOccurrences(of: " ", with: "T")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate,
                             .withColonSeparatorInTime, .withFullDate]
        if let date = iso.date(from: normalized) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss",
                       "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    private static func formatDate(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Không giới hạn" }
        let normalized = raw.replacingOccurrences(of: " ", with: "T")
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate,
                             .withColonSeparatorInTime, .withFullDate]
        let parsed = fmt.date(from: normalized)
            ?? {
                let f2 = DateFormatter()
                f2.locale = Locale(identifier: "vi_VN")
                f2.dateFormat = "yyyy-MM-dd HH:mm:ss"
                return f2.date(from: raw)
            }()
        guard let d = parsed else { return raw }
        let out = DateFormatter()
        out.locale     = Locale(identifier: "vi_VN")
        out.dateFormat = "HH:mm - dd/MM/yyyy"
        return out.string(from: d)
    }

    // ── canAutoLogin: có key đã lưu + uid khớp máy → không cần nhập lại ─
    var canAutoLogin: Bool {
        let key = savedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let uid = boundDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !key.isEmpty && uid == DeviceUID.current
    }

    // ── verifyKey ────────────────────────────────────────────────────────
    func verifyKey(inputKey: String? = nil) {
        verificationGeneration &+= 1
        let generation = verificationGeneration

        verificationTask?.cancel()
        verificationTask = nil
        verificationSession?.invalidateAndCancel()
        verificationSession = nil

        isAuthenticating = true
        errorMessage     = nil

        let key = (inputKey ?? savedKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard !key.isEmpty else {
            isAuthorized = false
            isAuthenticating = false
            return
        }
        guard let url = endpoint(for: key) else {
            errorMessage     = "Lỗi cấu hình API"
            isAuthenticating = false
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod  = "GET"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ThreeOneOSFive/1.0 CFNetwork", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let cfg  = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = 20
        cfg.timeoutIntervalForResource = 35
        cfg.waitsForConnectivity       = true

        let delegate = _RedirectDelegate()
        let session  = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        verificationSession = session

        let task = session.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.verificationGeneration == generation else { return }
                self.verificationTask = nil
                self.verificationSession?.finishTasksAndInvalidate()
                self.verificationSession = nil
                self.isAuthenticating = false

                // ── Network errors ──
                if let err = error as NSError? {
                    switch err.code {
                    case NSURLErrorHTTPTooManyRedirects:
                        self.errorMessage = "Server chuyển hướng quá nhiều lần — liên hệ Admin"
                    case NSURLErrorTimedOut:
                        self.errorMessage = "Hết thời gian kết nối — kiểm tra mạng"
                    case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                        self.errorMessage = "Không có kết nối Internet"
                    case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                        self.errorMessage = "Không thể kết nối máy chủ"
                    default:
                        self.errorMessage = "Lỗi kết nối máy chủ"
                    }
                    return
                }

                // ── Parse JSON ──
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    self.errorMessage = "Phản hồi máy chủ không hợp lệ"
                    return
                }

                // ── API contract (mirrors checkkey.html render()) ──
                let valid    = json["valid"]      as? Bool   ?? false
                let expiresAt = json["expires_at"] as? String
                let appName  = json["app_name"]   as? String ?? "Thành Viên VIP"
                let lifetime = json["lifetime"]   as? Bool   ?? false
                let note     = json["note"]        as? String ?? ""
                let message  = json["message"]     as? String
                    ?? json["msg"]    as? String
                    ?? json["error"]  as? String

                if valid {
                    // Bind UID máy vào key — persist qua DeviceUID (Keychain)
                    self.boundDeviceUID     = DeviceUID.current
                    UserDefaults.standard.set(true, forKey: "web_patch_apply_enabled")
                    self.isAuthorized       = true
                    self.savedKey           = key
                    self.keyName            = appName
                    self.keyLifetime        = lifetime
                    self.keyNote            = note
                    self.keyDuration        = lifetime ? "Vĩnh viễn" : "Có thời hạn"
                    self.keyExpiry          = lifetime
                        ? "Vĩnh viễn"
                        : KeyAuthManager.formatDate(expiresAt)
                    self.keyExpiryTimestamp = lifetime
                        ? 0
                        : (KeyAuthManager.parseDate(expiresAt)?.timeIntervalSince1970 ?? 0)
                    self.isPatchVisible     = true
                    self.errorMessage       = nil
                    self.isActivationTransitioning = true
                    self.startPatchAccessPolicyMonitor()
                    self.startRuntimeStatusMonitor()
                    self.startWebPatchPollMonitor()

                    if AppRuntimeConfig.shared.maintenanceMode {
                        self.enterMaintenanceMode()
                    }

                    let transitionDuration = AppearanceSettings.shared.animationsEnabled ? 1.15 : 0.05
                    DispatchQueue.main.asyncAfter(deadline: .now() + transitionDuration) { [weak self] in
                        self?.isActivationTransitioning = false
                    }
                } else {
                    self.isAuthorized   = false
                    self.savedKey       = ""
                    self.keyName        = ""
                    self.keyDuration    = ""
                    self.keyExpiry      = ""
                    self.keyNote        = ""
                    self.keyLifetime    = false
                    self.boundDeviceUID = ""
                    self.errorMessage   = message ?? "Key không hợp lệ hoặc đã hết hạn"
                }
            }
        }
        verificationTask = task
        task.resume()
    }

    // ── Web patch toggle poll (10 giây/lần) ─────────────────────────────
    private func startWebPatchPollMonitor() {
        webPatchPollTask?.cancel()
        webPatchPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isAuthorized else { return }
                await self.fetchWebPatchState()
                do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                catch { return }
            }
        }
    }

    private func fetchWebPatchState() async {
        let key = savedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Must use the same device_id that patch_heartbeat.php stores on the server.
        // PatchToggleStore generates/persists this UUID under "fluxcore.heartbeat.device_id"
        // in UserDefaults. DeviceUID.current is a different Keychain-bound identifier and
        // will never match the key stored by the heartbeat → device-level toggle would be ignored.
        let heartbeatKey = "fluxcore.heartbeat.device_id"
        let uid: String = {
            if let existing = UserDefaults.standard.string(forKey: heartbeatKey),
               UUID(uuidString: existing) != nil {
                return existing
            }
            // Fallback: generate and persist so both sides agree from first poll
            let generated = UUID().uuidString.lowercased()
            UserDefaults.standard.set(generated, forKey: heartbeatKey)
            return generated
        }()
        let keySafe = key.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_"))) ?? key
        let uidSafe = uid.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-"))) ?? uid
        guard !keySafe.isEmpty,
              let url = URL(string: wedProxyBaseURL + keySafe + "&device_id=" + uidSafe) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.cachePolicy     = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = json["patch_enabled"] as? Bool
        else { return }
        // disabled_patches: ["1","3"...] — patch server ID bị admin tắt riêng lẻ
        let disabledPatchIDs = json["disabled_patches"] as? [String] ?? []

        await MainActor.run {
            let previousEnabled     = self.webPatchEnabled
            let previousDisabledIDs = self.webDisabledPatchIDs

            self.webPatchEnabled     = enabled
            self.webDisabledPatchIDs = Set(disabledPatchIDs)
            UserDefaults.standard.set(enabled, forKey: "web_patch_apply_enabled")
            // Persist disabled set → restart không re-fire notifications cho patch đã tắt sẵn
            UserDefaults.standard.set(Array(self.webDisabledPatchIDs),
                                      forKey: "fluxcore.webDisabledPatchIDs.persisted")

            // ── Global toggle thay đổi → báo PatchToggleStore bật/tắt toàn bộ ──
            if enabled != previousEnabled {
                NotificationCenter.default.post(
                    name: .fluxCoreWebPatchToggled,
                    object: nil,
                    userInfo: ["enabled": enabled]
                )
            }

            // ── Per-patch thay đổi → báo PatchToggleStore xử lý từng patch ──
            let newDisabled = self.webDisabledPatchIDs.subtracting(previousDisabledIDs)
            let newEnabled  = previousDisabledIDs.subtracting(self.webDisabledPatchIDs)

            if !newDisabled.isEmpty {
                NotificationCenter.default.post(
                    name: .fluxCoreWebPatchIDsDisabled,
                    object: nil,
                    userInfo: ["patch_ids": Array(newDisabled)]
                )
            }
            if !newEnabled.isEmpty {
                NotificationCenter.default.post(
                    name: .fluxCoreWebPatchIDsEnabled,
                    object: nil,
                    userInfo: ["patch_ids": Array(newEnabled)]
                )
            }
        }
    }

    // ── Patch access policy monitor ─────────────────────────────────────
    private func startPatchAccessPolicyMonitor() {
        patchPolicyTask?.cancel()
        patchPolicyTask = nil
        patchRemainingSeconds = PatchAccessPolicy.remainingSeconds()
        patchAccessWarning = nil

        guard PatchAccessPolicy.remainingSeconds() != nil else { return }

        patchPolicyTask = Task { @MainActor [weak self] in
            var cleanupTriggered = false

            while !Task.isCancelled {
                guard let self, self.isAuthorized else { return }

                let remaining = PatchAccessPolicy.remainingSeconds()
                self.patchRemainingSeconds = remaining

                if let remaining {
                    if remaining <= PatchAccessPolicy.warningWindow {
                        self.isPatchVisible = false
                        self.patchAccessWarning = "Key sắp hết hạn (≤ 3600 giây). Tất cả Patch đã được khóa và hệ thống đang khôi phục file gốc."

                        if !cleanupTriggered {
                            cleanupTriggered = true
                            let result = await Task.detached(priority: .utility) {
                                PatchAccessPolicy.enforce()
                            }.value

                            guard !Task.isCancelled else { return }

                            if !result.failed.isEmpty {
                                self.patchAccessWarning = "Key sắp hết hạn; một số Patch cũ chưa thể khôi phục tự động. Vui lòng kiểm tra lại file gốc."
                            }
                        }
                    } else {
                        self.patchAccessWarning = nil
                    }
                }

                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    // ── Runtime status monitor ──────────────────────────────────────────
    private func startRuntimeStatusMonitor() {
        runtimeStatusTask?.cancel()
        runtimeStatusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = await AppRuntimeConfig.shared.refresh()
                let config = AppRuntimeConfig.shared
                if config.appLocked || config.maintenanceMode {
                    if !self.isMaintenanceMode {
                        self.enterMaintenanceMode()
                    }
                } else if self.isMaintenanceMode && !self.savedKey.isEmpty {
                    self.leaveMaintenanceMode()
                }
                let seconds = max(5.0, config.maintenanceInterval)
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    func enterMaintenanceMode() {
        verificationGeneration &+= 1
        verificationTask?.cancel()
        verificationTask = nil
        verificationSession?.invalidateAndCancel()
        verificationSession = nil
        isMaintenanceMode = true
        isAuthorized = true
        isAuthenticating = false
        isPatchVisible = false
        isExitingApp = false
        errorMessage = nil
    }

    func leaveMaintenanceMode() {
        isMaintenanceMode = false
        isPatchVisible = true
        if savedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isAuthorized = false
        }
    }

    func logout() {
        patchPolicyTask?.cancel();   patchPolicyTask   = nil
        runtimeStatusTask?.cancel(); runtimeStatusTask = nil
        webPatchPollTask?.cancel();  webPatchPollTask  = nil
        verificationGeneration &+= 1
        verificationTask?.cancel();  verificationTask  = nil
        verificationSession?.invalidateAndCancel(); verificationSession = nil

        // Xoá key nhưng GIỮ boundDeviceUID (uid gắn máy vật lý, không phải user)
        ["saved_key","key_name","key_duration","key_expiry","key_note","key_expiry_timestamp"].forEach {
            UserDefaults.standard.removeObject(forKey: $0)
        }
        UserDefaults.standard.set(false, forKey: "key_lifetime")

        savedKey            = ""
        keyName             = ""
        keyDuration         = ""
        keyExpiry           = ""
        keyExpiryTimestamp  = 0
        keyNote             = ""
        keyLifetime         = false

        errorMessage        = nil
        isAuthenticating    = false
        isAuthorized        = false
        isPatchVisible      = true
        patchRemainingSeconds = nil
        patchAccessWarning  = nil
        isExitingApp        = false
        isMaintenanceMode   = false
        webPatchEnabled     = true
        webDisabledPatchIDs = []
        UserDefaults.standard.set(true,    forKey: "web_patch_apply_enabled")
        UserDefaults.standard.removeObject(forKey: "fluxcore.webDisabledPatchIDs.persisted")
    }

    private func triggerMaintenanceSequence() {
        isExitingApp = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { exit(0) }
    }
}

// MARK: _RedirectDelegate
private final class _RedirectDelegate: NSObject, URLSessionTaskDelegate {
    private var hops = 0
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        hops += 1
        guard hops <= 2 else { completionHandler(nil); return }
        var r = request
        if var c = URLComponents(url: request.url ?? URL(string: "https://")!,
                                 resolvingAgainstBaseURL: false), c.scheme == "http" {
            c.scheme = "https"; r.url = c.url ?? request.url
        }
        completionHandler(r)
    }
}

private struct KeyExpirationWarningBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .bold))
            Text(message)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.leading)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.yellow.opacity(0.35), lineWidth: 1)
        )
        .shadow(radius: 8)
    }
}

// MARK: - 2. Maintenance view
struct MaintenanceView: View {
    @ObservedObject var config: AppRuntimeConfig
    @State private var isPresented = true
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            Color.black.opacity(0.66)
                .ignoresSafeArea()
                .blur(radius: isPresented ? 0 : 0.1)

            if isPresented {
                VStack(spacing: 18) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(AppTheme.accent)
                        .shadow(color: AppTheme.accent.opacity(0.65), radius: 16)

                    Text(config.appLocked ? "ỨNG DỤNG ĐANG BỊ KHÓA" : "HỆ THỐNG BẢO TRÌ")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(.white)

                    Text(config.maintenanceNotice)
                        .font(.system(size: config.maintenanceFontSize, weight: .medium, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)

                    if !config.updateBoxButtonURL.isEmpty,
                       let updateURL = URL(string: config.updateBoxButtonURL) {
                        Button {
                            UIApplication.shared.open(updateURL)
                        } label: {
                            Label(config.updateBoxButtonText, systemImage: "arrow.down.circle.fill")
                                .font(.system(size: 14, weight: .bold))
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    let legacyButtons = config.maintenanceButtons.filter { $0.url != config.updateBoxButtonURL }
                    if !legacyButtons.isEmpty {
                        ForEach(legacyButtons) { button in
                            Button(button.label) {
                                guard let url = URL(string: button.url) else { return }
                                UIApplication.shared.open(url)
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        }
                    }

                    // Không có nút đóng: trạng thái khóa/bảo trì là gate bắt buộc.
                    // Chỉ máy chủ tắt trạng thái mới cho phép quay lại chức năng chính.
                }
                .padding(28)
                .frame(maxWidth: 560)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(.white.opacity(0.13), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.55), radius: 40, y: 20)
                .padding(.horizontal, 20)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isPresented)
        .onAppear { scheduleTimer() }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: config.maintenanceInterval, repeats: true) { _ in
            DispatchQueue.main.async { isPresented = true }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
}

// MARK: - 3. Key Activation view
/// Premium activation surface shared by first-launch and re-authentication flows.
/// The wallpaper remains visible outside the protected card, while the card and
/// input control use layered materials/tints so app content cannot bleed through.
// MARK: - KeyActivationView
/// Modern monochrome key-login screen.
/// The key is the first user-facing gate; patch/video startup begins only
/// after successful verification.
struct KeyActivationView: View {
    @ObservedObject var authManager: KeyAuthManager
    @State private var inputKey:       String = ""
@State private var keyVisible:    Bool   = false
    @State private var appeared:       Bool   = false
    @State private var cardSlid:       Bool   = false
    @State private var showDevMenu:    Bool   = false
    @State private var btnPressed:     Bool   = false
    @State private var moonbeamOffset: CGFloat = -1.35
    @FocusState private var focused:   Bool
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var showSettingsSheet = false

    private var isFuturisticTheme: Bool {
        appearance.appThemeMode == .futuristic
    }

    private var primaryTextColor: Color {
        isFuturisticTheme ? .white : Color.black.opacity(0.88)
    }

    private var secondaryTextColor: Color {
        isFuturisticTheme ? cMuted : Color.black.opacity(0.56)
    }

    private var loginBackgroundColor: Color {
        appearance.resolvedKeyLoginBackgroundColor
    }

    private var loginBorderColor: Color {
        // Fixed modern dark-tech accent: charcoal/graphite for the monochrome login UI.
        Color(red: 0.34, green: 0.39, blue: 0.46)
    }

    private var loginCornerRadius: CGFloat {
        CGFloat(min(max(appearance.keyLoginCornerRadius, 12), 36))
    }

    // Monochrome tech palette
    private let cAccent  = Color.white
    private let cGreen   = Color.white
    private let cRed     = Color.white
    private let cWarn    = Color(red: 1.000, green: 0.718, blue: 0.012)  // #ffb703
    private let cBG1     = Color.black
    private let cBG2     = Color(red: 0.10, green: 0.11, blue: 0.13)
    private let cMuted   = Color.white.opacity(0.62)
    private let cCard    = Color.black.opacity(0.88)

    var body: some View {
        ZStack {
            // ── Background: animated gradient matching HTML ──
            ZStack {
                LinearGradient(
                    colors: isFuturisticTheme
                        ? [loginBackgroundColor, Color(red: 0.015, green: 0.02, blue: 0.04)]
                        : [loginBackgroundColor, Color.white.opacity(0.96)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                // Radial accents
                RadialGradient(colors: [cAccent.opacity(isFuturisticTheme ? 0.13 : 0.05), .clear],
                               center: .init(x: 0.1, y: -0.05),
                               startRadius: 0, endRadius: 650)
                RadialGradient(colors: [cGreen.opacity(isFuturisticTheme ? 0.10 : 0.035), .clear],
                               center: .init(x: 1.1, y: 0.1),
                               startRadius: 0, endRadius: 520)
                // Background wallpaper if set
                GlobalBackground().opacity(isFuturisticTheme ? 0.16 : 0.05)
            }
            .ignoresSafeArea()

            // ── Content: mathematically centered in the available screen ──
            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        loginCard
                            .frame(maxWidth: 460)
                            .frame(maxWidth: .infinity)
                            .offset(y: cardSlid ? 0 : 24)
                            .opacity(cardSlid ? 1 : 0)
                    }
                    .frame(minHeight: max(geometry.size.height, 1),
                           alignment: .center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
        .overlay {
            if showDevMenu {
                DevInfoPopup(isPresented: $showDevMenu)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal:   .move(edge: .bottom).combined(with: .opacity)
                    ))
                    .zIndex(100)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: showDevMenu)
        .animation(.easeOut(duration: 0.20), value: authManager.isAuthenticating)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: authManager.errorMessage)
        .onAppear {
            inputKey = authManager.savedKey
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.55)) { cardSlid = true }
            withAnimation(.spring(response: 0.60, dampingFraction: 0.82).delay(0.15)) { appeared = true }
        }
    }

    // ── Main glass card ──
    private var loginCard: some View {
        VStack(spacing: 0) {
            // ─ Logo row (mirrors .logo) ─
            HStack(spacing: 12) {
                // Badge with key icon + warn glow
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(
                            RadialGradient(colors: [Color.white.opacity(0.08), .clear],
                                           center: .init(x: 0.3, y: 0.2),
                                           startRadius: 0, endRadius: 46)
                        )
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.11, green: 0.08, blue: 0.20),
                                                      Color(red: 0.04, green: 0.03, blue: 0.08)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(cAccent)
                }
                .frame(width: 46, height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.clear, lineWidth: 0)
                )
                .shadow(color: cAccent.opacity(0.40), radius: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Kiểm tra License Key")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(primaryTextColor)
                    Text("APP FLUXCORE")
                        .font(.system(size: 12.5))
                        .foregroundColor(secondaryTextColor)
                }
                Spacer()
            }
            .padding(.horizontal, 30)
            .padding(.top, 34)
            .padding(.bottom, 24)

            Divider()
                .background((isFuturisticTheme ? Color.white : Color.black).opacity(0.10))
                .padding(.horizontal, 30)

            // ─ Input + button ─
            VStack(spacing: 14) {

                // Label
                HStack {
                    Text("Nhập Key")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(secondaryTextColor)
                    Spacer()
                }

                // Input field
                keyField

                // Action button
                activateButton

                // ─ Result card (mirrors res-card) ─
                if authManager.isAuthenticating {
                    loadingRow
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let err = authManager.errorMessage {
                    errorCard(err)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if authManager.isAuthorized {
                    successCard
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }

            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)

            // ─ Developer Info (below card, matches .foot) ─
            DeveloperInfoCard {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { showDevMenu = true }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 30)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
            .animation(.spring(response: 0.55, dampingFraction: 0.88).delay(0.12), value: appeared)
        }
        .background {
            // Production login surface: deep pitch-black with a subtle technical tint.
            RoundedRectangle(cornerRadius: loginCornerRadius, style: .continuous)
                .fill(Color(red: 0.008, green: 0.010, blue: 0.016))
                .overlay {
                    RoundedRectangle(cornerRadius: loginCornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.022),
                                    Color.clear,
                                    cAccent.opacity(0.025)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        }
        .overlay {
            LoginMoonbeam(
                offset: moonbeamOffset,
                accent: cAccent,
                enabled: appearance.animationsEnabled
            )
            .clipShape(RoundedRectangle(cornerRadius: loginCornerRadius, style: .continuous))
            .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: loginCornerRadius, style: .continuous)
                .stroke(
                    loginBorderColor.opacity(0.72),
                    lineWidth: max(CGFloat(appearance.keyLoginBorderWidth), 1.0)
                )
                .shadow(
                    color: Color.black.opacity(0.82),
                    radius: 18
                )
        }
        .shadow(color: .black.opacity(0.78), radius: 34, y: 18)
        .onAppear {
            guard appearance.animationsEnabled else {
                moonbeamOffset = 0.10
                return
            }
            moonbeamOffset = -1.35
            withAnimation(
                .linear(duration: max(3.8, 6.0 * appearance.animationDurationMultiplier))
                    .repeatForever(autoreverses: false)
            ) {
                moonbeamOffset = 1.35
            }
        }
    }

    // ── Secure key input field ──
    private var keyField: some View {
        HStack(spacing: 8) {
            Group {
                if keyVisible {
                    TextField("XXXX-XXXX-XXXX-XXXX", text: $inputKey)
                } else {
                    SecureField("XXXX-XXXX-XXXX-XXXX", text: $inputKey)
                }
            }
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .focused($focused)
            .foregroundColor(primaryTextColor)
            .font(.system(size: 15, design: .monospaced))
            .tint(cAccent)
            .onChange(of: inputKey) { v in
                let upper = v.uppercased()
                if upper != v { inputKey = upper }
            }
            .onSubmit { submit() }

            Button {
                guard !inputKey.isEmpty else { return }
                UIPasteboard.general.string = inputKey
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(cAccent)
                    .frame(width: 34, height: 34)
                    .background(cAccent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain).techButtonChrome()
            .disabled(inputKey.isEmpty)
            .accessibilityLabel("Sao chép Key")

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    keyVisible.toggle()
                }
            } label: {
                Image(systemName: keyVisible ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(keyVisible ? cAccent : secondaryTextColor)
                    .frame(width: 34, height: 34)
                    .background(
                        (keyVisible ? cAccent : Color.white).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            }
            .buttonStyle(.plain).techButtonChrome()
            .accessibilityLabel(keyVisible ? "Ẩn Key" : "Hiện Key")

            Button {
                guard let p = UIPasteboard.general.string else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    inputKey = p.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(cAccent)
                    .frame(width: 34, height: 34)
                    .background(cAccent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain).techButtonChrome()
            .accessibilityLabel("Dán Key")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(isFuturisticTheme ? Color.black.opacity(0.42) : Color.white.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(
                    focused
                        ? Color(red: 0.42, green: 0.48, blue: 0.56).opacity(0.78)
                        : Color(red: 0.20, green: 0.24, blue: 0.29).opacity(0.92),
                    lineWidth: focused ? 1.15 : 0.85
                )
                .shadow(
                    color: focused ? Color.black.opacity(0.65) : .clear,
                    radius: 7
                )
        }
        .animation(.easeInOut(duration: 0.18), value: focused)
    }

    // ── Activate button (monochrome tech treatment) ──
    private var activateButton: some View {
        Button { submit() } label: {
            HStack(spacing: 8) {
                if authManager.isAuthenticating {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.85)
                        .transition(.opacity)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .bold))
                }
                Text(authManager.isAuthenticating ? "Đang kiểm tra..." : "Kích Hoạt Key")
                    .fontWeight(.bold)
                    .font(.system(size: 14.5))
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).techButtonChrome()
        .foregroundColor(primaryTextColor)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.055, green: 0.067, blue: 0.082),
                    Color(red: 0.015, green: 0.020, blue: 0.028),
                    Color(red: 0.095, green: 0.112, blue: 0.135)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
        }
        .shadow(color: Color.black.opacity(0.70), radius: 16, y: 8)
        .scaleEffect(authManager.isActivationTransitioning ? 0.82 : (btnPressed ? 0.97 : 1.0))
        .brightness(btnPressed ? -0.04 : 0)
        .animation(.easeOut(duration: 0.12), value: btnPressed)
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: authManager.isActivationTransitioning)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in btnPressed = true }
            .onEnded   { _ in btnPressed = false }
        )
        .disabled(authManager.isAuthenticating || inputKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .opacity(inputKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.62 : 1)
    }

    // ── Loading row ──
    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView().tint(cAccent).scaleEffect(0.85)
            Text("Đang kiểm tra key...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(secondaryTextColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(cAccent.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
        }
    }

    // ── Error card (res-bad) ──
    private func errorCard(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 10) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(cRed)
                Text(msg)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color(red: 1.0, green: 0.561, blue: 0.639)) // #ff8fa3
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
        }
        .background(cRed.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
        }
    }

    // ── Success card (res-ok) ──
    private var successCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(cGreen)
                Text("Key hợp lệ")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color(red: 0.357, green: 0.890, blue: 0.643)) // #5be3a4
                Spacer()
                // Logout
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        authManager.logout()
                        inputKey = ""
                    }
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(cRed)
                }
                .buttonStyle(.plain).techButtonChrome()
                .accessibilityLabel("Đăng xuất key")
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider().background((isFuturisticTheme ? Color.white : Color.black).opacity(0.08)).padding(.horizontal, 18)

            // Rows (mirrors row() in HTML)
            VStack(spacing: 0) {
                resultRow(key: "Ứng dụng",    value: authManager.keyName,
                          isMono: false)
                resultRow(key: "Hạn sử dụng", value: authManager.keyExpiry,
                          isMono: true)
                if !authManager.keyNote.isEmpty {
                    resultRow(key: "Ghi chú", value: authManager.keyNote, isMono: false)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .background(cGreen.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
        }
    }

    // ── Table row ──
    private func resultRow(key: String, value: String, isMono: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key)
                .font(.system(size: 13))
                .foregroundColor(secondaryTextColor)
            Spacer()
            Text(value)
                .font(isMono
                      ? .system(size: 13, weight: .semibold, design: .monospaced)
                      : .system(size: 13, weight: .semibold))
                .foregroundColor(primaryTextColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            Divider().background((isFuturisticTheme ? Color.white : Color.black).opacity(0.06))
        }
    }

    // ── Submit ──
    private func submit() {
        focused = false
        let trimmed = inputKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !authManager.isAuthenticating else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            authManager.verifyKey(inputKey: trimmed)
        }
    }
}

// MARK: - 4. ContentView
struct ContentView: View {
    @Environment(\.appLanguage)       private var language
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var patchDraftCoordinator: PatchDraftCoordinator
    @EnvironmentObject private var repositoryStore: PackageRepositoryStore
    @EnvironmentObject private var repositoryPatchStore: PatchProjectStore
    @EnvironmentObject private var startupLoader: StartupResourceLoader
    @State private var tabNavigation: AppTabNavigationState
    @AppStorage(FeatureVisibility.cleanerStorageKey)    private var cleanerEnabled    = true
    @AppStorage(FeatureVisibility.wallpapersStorageKey) private var wallpapersEnabled = true
    @StateObject private var authManager = KeyAuthManager()
    @StateObject private var chatService = FluxChatService.shared
    @ObservedObject private var runtimeConfig = AppRuntimeConfig.shared
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var showSettingsSheet = false
    @State private var homeNavigationDepth = 0
    @State private var appNavigationDepth = 0
    @Environment(\.scenePhase) private var scenePhase
    @State private var showReentryAnimation = false
    @State private var hasEnteredBackground = false
    @State private var startupComplete = false
    @State private var startupTask: Task<Void, Never>?
    @State private var homepageNotice: FluxHomepageNotice?
    @State private var showHomepageNotice = false
    @State private var isLoadingHomepageNotice = false
    @State private var reloadHomepageNoticeAfterCurrent = false

    init() {
#if targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        let restored = AppTabNavigationStore.load()
        _tabNavigation = State(initialValue: args.contains("--simulate-patch-tab")
            ? AppTabNavigationState(selectedTab: AppSection.files.rawValue)
            : (restored ?? AppTabNavigationState()))
#else
        _tabNavigation = State(initialValue: AppTabNavigationStore.load() ?? AppTabNavigationState())
#endif
    }

    var body: some View {
        ZStack {
            if authManager.isAuthorized && (startupComplete || authManager.isMaintenanceMode) {
                Group {
                    if horizontalSizeClass == .regular { regularLayout } else { compactLayout }
                }
                .tint(appearance.resolvedGlobalAccent)
                .imageScale(.small)
                .opacity(appearance.globalOpacity)
                .onChange(of: patchDraftCoordinator.request?.id) {
                if $0 != nil { tabNavigation.select(AppSection.patches.rawValue) }
            }
            .onChange(of: patchDraftCoordinator.importRequest?.id) {
                if $0 != nil { tabNavigation.select(AppSection.patches.rawValue) }
            }
            .onChange(of: cleanerEnabled)    { _ in tabNavigation.reconcileSelection(with: featureVisibility) }
            .onChange(of: wallpapersEnabled) { _ in tabNavigation.reconcileSelection(with: featureVisibility) }
            .onChange(of: tabNavigation) { newState in
                // Persist every navigation mutation immediately; this covers tab
                // selection, tab renames, closes, and file navigation changes.
                AppTabNavigationStore.save(newState)
                if AppSection(rawValue: newState.selectedTab) != .patches {
                    appNavigationDepth = 0
                }
                if AppSection(rawValue: newState.selectedTab) != .home {
                    homeNavigationDepth = 0
                }
            }
            }

            FluxStatusNotificationBanner()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 10)
                .padding(.trailing, 12)
                .zIndex(9_000)
                .allowsHitTesting(false)

            if authManager.isAuthorized, let warning = authManager.patchAccessWarning {
                KeyExpirationWarningBanner(message: warning)
                    .padding(.horizontal, 14)
                    .padding(.top, 54)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .zIndex(9_500)
                    .allowsHitTesting(false)
            }

            if authManager.isAuthorized && chatService.passwordGateRequired && !chatService.passwordGateUnlocked {
                FluxPasswordGateView(
                    key: authManager.savedKey,
                    service: chatService
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(9_900)
            }

            if authManager.isAuthorized && !startupComplete && !authManager.isMaintenanceMode {
                StartupLoadingView(
                    loader: startupLoader,
                    onSkipFailedPatch: {
                        guard startupLoader.canSkipFailedPatch else { return }
                        startupLoader.skipFailedPatch()
                        startupComplete = true
                    }
                )
                .transition(.opacity)
                .zIndex(9_800)
            }

            if authManager.isMaintenanceMode {
                MaintenanceView(config: AppRuntimeConfig.shared)
                    .transition(.opacity)
                    .zIndex(1000)
            } else if authManager.isExitingApp {
                MaintenanceView(config: AppRuntimeConfig.shared)
                    .transition(.opacity)
                    .zIndex(1000)
            } else if !authManager.isAuthorized {
                KeyActivationView(authManager: authManager).transition(.opacity).zIndex(999)
            }

            if authManager.isActivationTransitioning {
                LicenseActivationTransitionView()
                    .transition(.opacity)
                    .zIndex(2_000)
            }

            if showReentryAnimation {
                AppReentryAnimationView()
                    .transition(.opacity)
                    .zIndex(2_100)
            }
        }
        .overlay(alignment: .topTrailing) {
            if shouldShowSettingsButton {
                Button {
                    showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(AppTheme.accent.opacity(0.42), lineWidth: 1))
                        .shadow(color: AppTheme.accent.opacity(0.22), radius: 10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cài đặt")
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .topTrailing)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: shouldShowSettingsButton)
        .sheet(isPresented: $showSettingsSheet) {
            NavigationStack {
                SettingsView(showsDoneButton: false)
            }
        }
        .repositoryStorePresentation(repositoryStore, patchStore: repositoryPatchStore)
        .onAppear {
            Task { @MainActor in
                await DeveloperInfoConfig.shared.refresh()
            }
            // Every fresh app launch starts at Home, regardless of the last saved tab.
            // Keep the current tab snapshot for normal in-session navigation only.
            tabNavigation.select(AppSection.home.rawValue)
            homeNavigationDepth = 0
            appNavigationDepth = 0
            tabNavigation.reconcileSelection(with: featureVisibility)
            AppTabNavigationStore.save(tabNavigation)
            // Authentication is the first startup gate. Do not perform runtime,
            // patch, or video loading before the key has been verified.
            authManager.leaveMaintenanceMode()
            // Auto-login: nếu đã lưu key + uid khớp máy → không cần nhập lại
            if authManager.canAutoLogin {
                authManager.verifyKey()
            }
        }
        .onChange(of: authManager.isAuthorized) { authorized in
            startupTask?.cancel()
            startupTask = nil
            startupComplete = false

            guard authorized, !authManager.isMaintenanceMode else { return }

            startupTask = Task { @MainActor in
                // Resolve the Key password gate before exposing the application UI.
                await chatService.prepareForAppLaunch(key: authManager.savedKey)
                // This is the first point where patch/video resource loading may
                // start. It is reached only after successful key verification.
                let ready = await startupLoader.start()
                guard !Task.isCancelled else { return }
                if ready {
                    // Hold the success state long enough for the user to see it.
                    try? await Task.sleep(for: .milliseconds(1400))
                    guard !Task.isCancelled else { return }
                    startupComplete = true
                    // First-launch: scan and backup original files for status dot accuracy.
                    OriginalFileCollector.collectIfNeeded()
                    if FluxCoreAudioPlayer.shared.shouldPlayOnLaunch {
                        FluxCoreAudioPlayer.shared.play()
                    }
                    FloatingWindowManager.shared.show()
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .inactive, .background:
                hasEnteredBackground = phase == .background
                // Flush the lightweight UI snapshot at lifecycle boundaries.
                AppTabNavigationStore.save(tabNavigation)
            case .active:
                Task { @MainActor in
                    let loaded = await runtimeConfig.refresh()
                    guard loaded else { return }
                    if runtimeConfig.appLocked || runtimeConfig.maintenanceMode {
                        if authManager.isAuthorized || runtimeConfig.appLocked {
                            authManager.enterMaintenanceMode()
                            tabNavigation.select(AppSection.home.rawValue)
                        }
                    } else if authManager.isMaintenanceMode {
                        authManager.leaveMaintenanceMode()
                        authManager.verifyKey()
                    }
                }

                guard hasEnteredBackground else { break }
                hasEnteredBackground = false

                // Returning to foreground always restores Home and refreshes the
                // admin notice. Network errors are non-fatal and never block UI.
                if startupComplete && authManager.isAuthorized {
                    tabNavigation.select(AppSection.home.rawValue)
                    Task { await loadHomepageNoticeIfNeeded(force: true) }
                }

                guard appearance.animationsEnabled else { return }
                showReentryAnimation = true
                let duration = max(0.18, 0.46 * appearance.animationDurationMultiplier)
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    guard !hasEnteredBackground else { return }
                    showReentryAnimation = false
                }
            default:
                break
            }
        }
        .overlay {
            if showHomepageNotice, let notice = homepageNotice {
                FluxHomepageNoticeModal(notice: notice, onDismiss: {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                        showHomepageNotice = false
                    }
                }, onOpenLink: {
                    guard let url = notice.buttonURL else { return }
                    UIApplication.shared.open(url)
                })
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(20_000)
            }
        }
        .onChange(of: startupComplete) { completed in
            guard completed, authManager.isAuthorized else { return }
            // Requirement: show the Admin-configured notice on every fresh launch,
            // even if the same notice was dismissed during a previous session.
            Task { await loadHomepageNoticeIfNeeded(force: true) }
        }
        .animation(
            appearance.animationsEnabled
                ? .easeInOut(duration: 0.30 * appearance.animationDurationMultiplier)
                : nil,
            value: showReentryAnimation
        )
        .animation(.easeInOut(duration: 0.38), value: authManager.isAuthorized)
        .animation(.easeInOut(duration: 0.38), value: authManager.isMaintenanceMode)
        .preferredColorScheme(appearance.appThemeMode.swiftUIScheme)
    }

    @MainActor
    private func loadHomepageNoticeIfNeeded(force: Bool = false) async {
        if isLoadingHomepageNotice {
            if force { reloadHomepageNoticeAfterCurrent = true }
            return
        }
        guard let endpoint = URL(string: "https://appfluxcore.site/api/app_bootstrap.php?app=fluxcore"),
              endpoint.scheme?.lowercased() == "https", endpoint.host != nil else { return }
        isLoadingHomepageNotice = true
        defer {
            isLoadingHomepageNotice = false
            if reloadHomepageNoticeAfterCurrent {
                reloadHomepageNoticeAfterCurrent = false
                Task { @MainActor in
                    await loadHomepageNoticeIfNeeded(force: true)
                }
            }
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            let envelope = try JSONDecoder().decode(FluxHomepageBootstrap.self, from: data)
            guard let notice = envelope.adminNotice,
                  notice.enabled,
                  !notice.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                homepageNotice = nil
                showHomepageNotice = false
                return
            }
            // Admin notice is intentionally never remembered as dismissed.
            // Every fresh launch and foreground re-entry shows the current Web Admin notice.
            homepageNotice = notice
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                showHomepageNotice = true
            }
        } catch {
            // The popup is non-critical. Network/decode errors must never block app startup.
            log("homepage-notice: \(error.localizedDescription)")
        }
    }

    private var allowedSections: [AppSection] {
        if authManager.isMaintenanceMode {
            return [.home]
        }
        var s: [AppSection] = [.home]
        if authManager.isPatchVisible && authManager.webPatchEnabled { s.append(.patches) }
        return s
    }

    private var compactLayout: some View {
        TabView(selection: tabSelection) {
            ForEach(featureVisibility.visibleSections.filter { allowedSections.contains($0) }) { section in
                sectionContent(section)
                    .tabItem { CompactTabLabel(title: language.text(section.titleKey), systemImage: section.systemImage) }
                    .tag(section.rawValue)
            }
        }
    }

    private var regularLayout: some View {
        NavigationSplitView {
            List {
                ForEach(featureVisibility.visibleSections.filter { allowedSections.contains($0) }) { section in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                            tabNavigation.select(section.rawValue)
                        }
                    } label: {
                        Label(language.text(section.titleKey), systemImage: section.systemImage)
                            .fontWeight(section.rawValue == tabNavigation.selectedTab ? .semibold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).techButtonChrome()
                    .listRowBackground(
                        section.rawValue == tabNavigation.selectedTab
                            ? AppTheme.accent.opacity(0.14) : Color.clear)
                }
            }
            // REQ 6: no "3105" title
            .navigationTitle("")
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            sectionContent(selectedVisibleSection).id(selectedVisibleSection.rawValue)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func sectionContent(_ section: AppSection) -> some View {
        TechPageChrome {
            switch section {
            case .home:
                DashboardView(
                    cleanerEnabled: $cleanerEnabled,
                    wallpapersEnabled: $wallpapersEnabled,
                    wallpapersSupported: wallpapersSupported
                )
            case .files:      AppDataBrowserView(tabSession: filesTabSession)
            case .patches:
                VStack(spacing: 14) {
                    CustomPatchButtonsSection()
                    PatchProjectsView(isAtRoot: Binding(
                        get: { appNavigationDepth == 0 },
                        set: { appNavigationDepth = $0 ? 0 : 1 }
                    ))
                }
            case .cleaner:    CleanerView()
            case .wallpapers: WallpaperLabView()
            case .chat:      FluxChatView()
            case .account:   FluxAccountView(service: FluxChatService.shared)
            }
        }
    }

    private var tabSelection: Binding<Int> {
        Binding(
            get: { tabNavigation.selectedTab },
            set: {
                guard !authManager.isMaintenanceMode else {
                    tabNavigation.select(AppSection.home.rawValue)
                    return
                }
                tabNavigation.select($0)
            }
        )
    }
    private var filesTabSession: Binding<FilesTabSession> {
        Binding(get: { tabNavigation.filesTabs }, set: { tabNavigation.setFilesTabs($0) })
    }
    private var featureVisibility: FeatureVisibility {
        FeatureVisibility(cleanerEnabled: cleanerEnabled,
                          wallpapersEnabled: wallpapersEnabled,
                          wallpapersSupported: wallpapersSupported)
    }
    private var wallpapersSupported: Bool {
        WallpaperFeatureSupportPolicy.isSupported(major: AppInfo.versionTuple.major)
    }
    private var selectedVisibleSection: AppSection {
        guard let s = AppSection(rawValue: tabNavigation.selectedTab),
              allowedSections.contains(s), featureVisibility.isVisible(s) else { return .home }
        return s
    }

    /// Settings is a derived UI state. There is no second "visible" flag, so
    /// switching tabs cannot leave stale Settings state behind.
    private var shouldShowSettingsButton: Bool {
        guard authManager.isAuthorized,
              startupComplete,
              !authManager.isMaintenanceMode else {
            return false
        }

        switch selectedVisibleSection {
        case .home:
            return homeNavigationDepth == 0
        case .patches:
            return appNavigationDepth == 0
        default:
            return false
        }
    }
}

// MARK: - 5. Tab label
private struct CompactTabLabel: View {
    let title: String; let systemImage: String
    @ViewBuilder var body: some View {
        if let img = UIImage(
            systemName: systemImage,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        )?.withRenderingMode(.alwaysTemplate) {
            Image(uiImage: img)
        } else {
            Image(systemName: systemImage).font(.system(size: 17, weight: .medium))
        }
        Text(title)
    }
}

private extension AppSection {

    var titleKey: String {
        switch self {
        case .home:       return "Trang Chủ"
        case .files:      return "tab.files"
        case .patches:    return "Ứng Dụng"
        case .cleaner:    return "tab.cleaner"
        case .wallpapers: return "tab.wallpapers"
        case .chat:      return "tab.chat"
        case .account:   return "tab.account"
        }
    }
    var systemImage: String {
        switch self {
        case .home:       return "house.fill"
        case .files:      return "folder.fill"
        case .patches:    return "app.fill"
        case .cleaner:    return "sparkles"
        case .wallpapers: return "photo.on.rectangle.angled"
        case .chat:      return "bubble.left.and.bubble.right.fill"
        case .account:   return "person.crop.circle.fill"
        }
    }
}

// MARK: - 6. LoopingVideoPlayer
/// Continuous AVPlayerLooper-backed playback for the animated anime background.
/// The player is owned by the UIKit view so SwiftUI layout updates never pause it.
struct LoopingVideoPlayer: UIViewRepresentable {
    let urlString: String

    final class PlayerView: UIView {
        var player: AVQueuePlayer?
        var playerLooper: AVPlayerLooper?
        var playerLayer: AVPlayerLayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer?.frame = bounds
        }

        deinit {
            player?.pause()
            playerLooper?.disableLooping()
            playerLayer?.player = nil
        }
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false

        guard let url = URL(string: urlString) else { return view }

        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = true

        let looper = AVPlayerLooper(player: player, templateItem: item)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds

        view.player = player
        view.playerLooper = looper
        view.playerLayer = layer
        view.layer.insertSublayer(layer, at: 0)

        // Animated mode must remain continuously active. SwiftUI updates only resize
        // the layer; they never call pause(), seek(), or recreate the player.
        player.play()
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer?.frame = uiView.bounds
        // Deliberately do not pause/restart here. SwiftUI can update this representable
        // frequently while the AVPlayer continues rendering frames uninterrupted.
    }
}

// MARK: - 7. PatchGuideModal (unchanged)
struct PatchGuideModal: View {
    @Binding var isPresented: Bool
    private let guideSteps: [(String, String)] = [
        ("1. Mở Tab", "Vào tab, bấm nút + và chọn Tạo mới."),
        ("2. Nhập Thông Tin", "Nhập tên dự án và bundle identifier của ứng dụng đích. Có thể đặt mật khẩu."),
        ("3. Tạo Workspace", "Bấm Xong để tạo dự án và workspace có thể chỉnh sửa trong Tệp → Workspace → Patches."),
        ("4. Đặt File Thay Thế", "Tạo đúng cây đường dẫn đích rồi đặt file thay thế vào vị trí tương ứng bên trong folder bundle."),
        ("5. Áp Dụng", "Bấm Áp Dụng để đồng bộ workspace vào gói .3105 đã mã hóa và ghi vào container ứng dụng."),
        ("6. Khôi Phục", "Bấm Khôi phục file gốc để trả lại trạng thái ban đầu trước khi áp dụng."),
        ("Lưu Ý Quan Trọng", "Đóng ứng dụng đích trong lúc áp dụng. Không đổi tên folder bundle. Chỉ dùng với ứng dụng thuộc sở hữu của bạn.")
    ]
    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
                .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isPresented = false } }
            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .foregroundColor(Color(red: 0.18, green: 0.52, blue: 1.0))
                            .font(.system(size: 18, weight: .semibold))
                        Text("Hướng Dẫn")
                            .font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                    }
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isPresented = false }
                    } label: {
                        ZStack {
                            Circle().fill(Color.white.opacity(0.1)).frame(width: 30, height: 30)
                            Text("×").font(.system(size: 20, weight: .medium)).foregroundColor(.white)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 14)
                Divider().background(Color.white.opacity(0.08))
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(Array(guideSteps.enumerated()), id: \.offset) { idx, step in
                            HStack(alignment: .top, spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(idx == guideSteps.count - 1
                                              ? Color.orange.opacity(0.18)
                                              : Color(red: 0.18, green: 0.52, blue: 1.0).opacity(0.15))
                                        .frame(width: 30, height: 30)
                                    Image(systemName: idx == guideSteps.count - 1
                                          ? "exclamationmark.triangle.fill" : "checkmark.circle")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(idx == guideSteps.count - 1
                                                         ? .orange
                                                         : Color(red: 0.18, green: 0.52, blue: 1.0))
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(step.0).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                                    Text(step.1).font(.system(size: 12))
                                        .foregroundColor(Color(white: 0.65))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(12)
                            .background(Color(red: 0.10, green: 0.12, blue: 0.18).opacity(0.7))
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.clear, lineWidth: 0))
                        }
                    }
                    .padding(16)
                }
            }
            .background(ZStack {
                Color(red: 0.06, green: 0.07, blue: 0.11)
                GridBackgroundView(spacing: 22, lineColor: Color.white.opacity(0.03))
            })
            .cornerRadius(24)
            .overlay(RoundedRectangle(cornerRadius: 24)
                .stroke(Color.clear, lineWidth: 0))
            .shadow(color: Color(red: 0.18, green: 0.52, blue: 1.0).opacity(0.18), radius: 30)
            .padding(.horizontal, 16).padding(.vertical, 40)
            .frame(maxHeight: UIScreen.main.bounds.height * 0.75)
        }
    }
}

// MARK: - Login moonbeam
/// Lightweight diagonal light streak used only inside the license-key panel.
private struct LoginMoonbeam: View {
    let offset: CGFloat
    let accent: Color
    let enabled: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.white.opacity(0.025),
                                Color.white.opacity(0.18),
                                accent.opacity(0.24),
                                Color.white.opacity(0.045),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(
                        width: max(proxy.size.height * 1.45, 280),
                        height: max(2.0, proxy.size.height * 0.018)
                    )
                    .blur(radius: 5)
                    .rotationEffect(.degrees(-24))
                    .position(
                        x: proxy.size.width * (0.5 + offset),
                        y: proxy.size.height * 0.50
                    )

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.white.opacity(0.10),
                                Color.white.opacity(0.72),
                                Color.white.opacity(0.10),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(
                        width: max(proxy.size.height * 0.90, 190),
                        height: 1.1
                    )
                    .rotationEffect(.degrees(-24))
                    .position(
                        x: proxy.size.width * (0.5 + offset),
                        y: proxy.size.height * 0.50
                    )
                    .opacity(enabled ? 1 : 0.18)
            }
        }
    }
}

// MARK: - Nút Patch tùy chỉnh do Web Admin quản lý
private struct CustomPatchButtonItem: Decodable, Identifiable {
    let id: String
    let name: String
    let urlString: String
    let imageURLString: String
    let sortOrder: Int
    enum CodingKeys: String, CodingKey {
        case id, name
        case urlString = "url"
        case imageURLString = "image_url"
        case sortOrder = "sort_order"
    }
    var url: URL? {
        guard let value = URL(string: urlString),
              ["https", "http"].contains(value.scheme?.lowercased() ?? ""),
              value.host != nil, value.user == nil, value.password == nil else { return nil }
        return value
    }
    var imageURL: URL? {
        guard let value = URL(string: imageURLString),
              ["https", "http"].contains(value.scheme?.lowercased() ?? ""),
              value.host != nil, value.user == nil, value.password == nil else { return nil }
        return value
    }
}

private struct CustomPatchButtonsPayload: Decodable {
    let ok: Bool
    let items: [CustomPatchButtonItem]
}

private struct CustomPatchButtonsSection: View {
    @State private var items: [CustomPatchButtonItem] = []
    @State private var isLoading = false
    private let endpoint = URL(string: "https://appfluxcore.site/api/patch_custom_buttons.php")!

    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2.fill").foregroundStyle(.cyan)
                        Text("Patch nổi bật").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        Spacer()
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(items) { item in
                                Button {
                                    guard let url = item.url else { return }
                                    UIApplication.shared.open(url)
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06))
                                            if let imageURL = item.imageURL {
                                                AsyncImage(url: imageURL) { phase in
                                                    if let image = phase.image { image.resizable().scaledToFill() }
                                                    else { Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 30)).foregroundStyle(.cyan.opacity(0.8)) }
                                                }
                                                .frame(width: 142, height: 100).clipped()
                                            } else {
                                                Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 30)).foregroundStyle(.cyan)
                                            }
                                        }
                                        .frame(width: 142, height: 100).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        Text(item.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading)
                                    }
                                    .frame(width: 142, alignment: .leading).padding(10)
                                    .background(LinearGradient(colors: [Color(red: 0.05, green: 0.10, blue: 0.17), Color(red: 0.08, green: 0.17, blue: 0.24)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.cyan.opacity(0.22), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(14)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else if isLoading {
                ProgressView("Đang đồng bộ nút Patch…").tint(.cyan).frame(maxWidth: .infinity)
            }
        }
        .task { await loadButtons() }
    }

    @MainActor private func loadButtons() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            let payload = try JSONDecoder().decode(CustomPatchButtonsPayload.self, from: data)
            guard payload.ok else { throw URLError(.cannotParseResponse) }
            items = payload.items.sorted { $0.sortOrder < $1.sortOrder }
        } catch {
            // Không chặn màn hình Patch nếu mạng/API tạm thời không khả dụng.
            log("custom-patch-buttons: \(error.localizedDescription)")
        }
    }
}

// MARK: - 8. VideoSection — videos managed from Web Admin
private struct TutorialVideoItem: Decodable, Identifiable {
    let id: String
    let label: String
    let url: String
    let imageURL: String?
    let sortOrder: Int
    enum CodingKeys: String, CodingKey {
        case id, label, url
        case imageURL = "image_url"
        case sortOrder = "sort_order"
    }
    var destinationURL: URL? {
        guard let value = URL(string: url),
              ["https", "http"].contains(value.scheme?.lowercased() ?? ""),
              value.host != nil, value.user == nil, value.password == nil else { return nil }
        return value
    }
    var thumbnailURL: URL? {
        guard let imageURL, let value = URL(string: imageURL),
              ["https", "http"].contains(value.scheme?.lowercased() ?? ""),
              value.host != nil, value.user == nil, value.password == nil else { return nil }
        return value
    }
}

private struct TutorialVideoPayload: Decodable {
    let videos: [TutorialVideoItem]
    enum CodingKeys: String, CodingKey { case videos = "tutorial_videos" }
}

struct VideoSection: View {
    @State private var videos: [TutorialVideoItem] = []
    @State private var selectedIndex = 0
    @State private var appear = false
    @State private var isLoading = false
    @State private var loadFailed = false

    private let endpoint = URL(string: "https://appfluxcore.site/api/app_bootstrap.php?app=fluxcore")!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Video hướng dẫn", systemImage: "play.rectangle.fill")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                if videos.count > 1 {
                    Text("\(selectedIndex + 1) / \(videos.count)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            if isLoading && videos.isEmpty {
                ProgressView("Đang tải video hướng dẫn…").tint(.cyan).frame(maxWidth: .infinity, minHeight: 180)
            } else if videos.isEmpty {
                Text(loadFailed ? "Không thể tải video. Vui lòng thử lại sau." : "Chưa có video hướng dẫn.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                TabView(selection: $selectedIndex) {
                    ForEach(Array(videos.enumerated()), id: \.element.id) { index, item in
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 18).fill(Color.black)
                            Group {
                                if let imageURL = item.thumbnailURL {
                                    AsyncImage(url: imageURL) { phase in
                                        if let image = phase.image {
                                            image.resizable().scaledToFill()
                                        } else {
                                            Image(systemName: "photo.fill")
                                                .font(.system(size: 34))
                                                .foregroundStyle(.white.opacity(0.55))
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        }
                                    }
                                } else {
                                    Image(systemName: "photo.fill")
                                        .font(.system(size: 34))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .onTapGesture {
                                if let destination = item.destinationURL {
                                    UIApplication.shared.open(destination)
                                }
                            }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Mở liên kết do quản trị viên thiết lập")
                            Text(item.label.isEmpty ? "Hướng dẫn" : item.label)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 11).padding(.vertical, 7)
                                .background(.black.opacity(0.62), in: Capsule())
                                .padding(12)
                        }
                        .tag(index)
                        .padding(.horizontal, 2)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: videos.count > 1 ? .automatic : .never))
                .frame(height: 210)
                .accessibilityHint("Vuốt sang trái hoặc phải để đổi video hướng dẫn")
            }
        }
        .padding(14)
        .background(LinearGradient(colors: [Color(red: 0.04, green: 0.08, blue: 0.14), Color(red: 0.06, green: 0.13, blue: 0.19)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.cyan.opacity(0.22), lineWidth: 1))
        .shadow(color: Color.cyan.opacity(0.16), radius: 16, y: 6)
        .scaleEffect(appear ? 1 : 0.97).opacity(appear ? 1 : 0)
        .task { await loadVideos() }
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { appear = true } }
    }

    @MainActor private func loadVideos() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var request = URLRequest(url: endpoint, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            let payload = try JSONDecoder().decode(TutorialVideoPayload.self, from: data)
            videos = payload.videos.filter { item in
                return item.destinationURL != nil
            }.sorted { $0.sortOrder < $1.sortOrder }
            selectedIndex = 0
            loadFailed = false
        } catch {
            loadFailed = true
            log("tutorial-videos: fetch failed – \(error.localizedDescription)")
        }
    }
}

// MARK: - 10. AutoPatchEngine (REQ 2 — continuous, tab-change & tap triggered)
@MainActor
final class AutoPatchEngine: ObservableObject {
    static let shared = AutoPatchEngine()

    @Published private(set) var isRunning = false
    @Published private(set) var hasCompleted = false
    @Published private(set) var completedCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var totalCount = 0

    private init() {}

    private var fetcher = OnlineFileFetcher()
    private weak var store: PatchProjectStore?
    private var fetchedFiles: [OnlineFileItem] = []

    func configure(store: PatchProjectStore) {
        self.store = store
        // A new PatchProjectsView owns a new store. The manifest can be reused,
        // but the import target must always be the current view's store.
    }

    func trigger() {
        guard !isRunning else { return }
        Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        guard let store, !isRunning else { return }

        isRunning = true
        hasCompleted = false
        completedCount = 0
        failedCount = 0
        totalCount = 0
        defer { isRunning = false }

        // Always refresh the server manifest. Keeping a permanent in-memory
        // manifest caused newly uploaded/public patches to remain invisible
        // until the application was relaunched. Local packages are still reused
        // by preloadAllPatches(), so refreshing the manifest does not redownload
        // packages that are already installed.
        await fetcher.fetchServerFiles()
        fetchedFiles = fetcher.onlineFiles

        totalCount = fetchedFiles.count
        guard !fetchedFiles.isEmpty else {
            hasCompleted = true
            return
        }

        _ = await fetcher.preloadAllPatches(
            files: fetchedFiles,
            store: store,
            progress: { [weak self] completed, _, failed, _ in
                guard let self else { return }
                self.completedCount = completed
                self.failedCount = failed
            },
            itemResult: { _, _ in }
        )

        store.reload()
        hasCompleted = true
    }

}

// MARK: - 11. DashboardView
// REQ 1: Settings moved to the main navigation bar
// REQ 2: Banner top-RIGHT; tap-anywhere trigger
// REQ 5: GlobalBackground applied
// REQ 6: no "3105" / "About 3105" / "patch" text in UI labels
private struct DashboardView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var appearance  = AppearanceSettings.shared
    @ObservedObject private var wallpaperPalette = DynamicWallpaperPalette.shared

    @State private var showDevInfo  = false
    @Binding var cleanerEnabled:    Bool
    @Binding var wallpapersEnabled: Bool
    let wallpapersSupported: Bool

    @AppStorage("saved_key")      private var savedKey:     String = ""
    @AppStorage("key_duration")   private var keyDuration:  String = ""
    @AppStorage("key_expiry")     private var keyExpiry:    String = ""
    @AppStorage("key_expiry_timestamp") private var keyExpiryTimestamp: Double = 0

    @State private var card1Appear  = false
    @State private var card2Appear  = false
    @State private var card3Appear  = false
    @State private var card4Appear  = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                // REQ 5: global background
                GlobalBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {

                        // Video
                        VideoSection()
                            .padding(.horizontal, 20)
                            .opacity(card1Appear ? 1 : 0).offset(y: card1Appear ? 0 : 20)

                        // Device info card
                        deviceInfoCard
                            .opacity(card2Appear ? 1 : 0).offset(y: card2Appear ? 0 : 20)

                        // Key info card
                        keyInfoCard
                            .opacity(card3Appear ? 1 : 0).offset(y: card3Appear ? 0 : 20)

                        // Developer Info
                        DeveloperInfoCard {
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                                showDevInfo = true
                            }
                        }
                        .padding(.horizontal, 20)
                        .opacity(card4Appear ? 1 : 0)
                        .offset(y: card4Appear ? 0 : 20)

                        Spacer(minLength: 24)
                    }
                    .padding(.vertical, 16)
                }
                .zIndex(1)

                // REQ 4: DevInfoPopup overlay
                if showDevInfo {
                    DevInfoPopup(isPresented: $showDevInfo)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal:   .move(edge: .bottom).combined(with: .opacity)
                        ))
                        .zIndex(200)
                }

            }
            .animation(.spring(response: 0.38, dampingFraction: 0.80), value: showDevInfo)
            // REQ 6: no "3105" navigation title
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                withAnimation(.spring(response: 0.50, dampingFraction: 0.80).delay(0.12))  { card1Appear  = true }
                withAnimation(.spring(response: 0.50, dampingFraction: 0.80).delay(0.20))  { card2Appear  = true }
                withAnimation(.spring(response: 0.50, dampingFraction: 0.80).delay(0.28))  { card3Appear  = true }
                withAnimation(.spring(response: 0.50, dampingFraction: 0.80).delay(0.36))  { card4Appear  = true }
            }
        }
    }

    // MARK: Sub-views

    private var deviceInfoCard: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "applelogo").foregroundColor(.pink).frame(width: 24)
                Text("Model").foregroundColor(Color(white: 0.7)).fontWeight(.medium)
                Spacer()
                Text(AppInfo.displayMachineName).foregroundColor(.white).fontWeight(.bold)
            }
            HStack {
                Image(systemName: "iphone")
                    .foregroundColor(Color(red: 0.18, green: 0.52, blue: 1.0)).frame(width: 24)
                Text("Device").foregroundColor(Color(white: 0.7)).fontWeight(.medium)
                Spacer()
                Text("\(AppInfo.osVersion) (\(AppInfo.osBuild))").foregroundColor(.white).fontWeight(.bold)
            }
            Divider().background(Color.white.opacity(0.1))
            HStack {
                Image(systemName: "checkmark.shield").foregroundColor(.yellow).frame(width: 24)
                Text("Tương thích").foregroundColor(Color(white: 0.7)).fontWeight(.medium)
                Spacer()
                Text(appState.isSupported ? "Thiết bị hỗ trợ" : "Thiết bị không hỗ trợ")
                    .foregroundStyle(appState.isSupported ? Color.green : Color.red).fontWeight(.semibold)
            }
        }
        .padding(20)
        .background(Color(red: 0.12, green: 0.12, blue: 0.18).opacity(appearance.dynamicOpacity))
        .cornerRadius(20)
        .techBorder(enabled: appearance.technologyBorderEnabled,
                    color: appearance.resolvedBorderColor,
                    cornerRadius: 20,
                    width: max(appearance.cardBorderWidth, 1.0))
        .padding(.horizontal, 20)
    }

    private var keyInfoCard: some View {
        // REQ 2: KeyInfoCard with masking + copy + eye toggle
        KeyInfoCard(
            savedKey:    savedKey,
            keyDuration: keyDuration,
            keyExpiry:   keyExpiry,
            expiryTimestamp: keyExpiryTimestamp,
            borderColor: appearance.resolvedBorderColor,
            bgOpacity:   appearance.dynamicOpacity,
            borderStyle: appearance.borderStyle
        )
        .padding(.horizontal, 20)
        .techBorder(enabled: appearance.technologyBorderEnabled,
                    color: appearance.resolvedBorderColor,
                    cornerRadius: 20,
                    width: max(appearance.cardBorderWidth, 1.0))
    }
    }

// MARK: - Lightweight app re-entry animation
private struct AppReentryAnimationView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.10)
                    .ignoresSafeArea()

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                appearance.resolvedBorderColor.opacity(0.10),
                                appearance.resolvedBorderColor.opacity(0.72),
                                appearance.resolvedBorderColor.opacity(0.10),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * 0.72, height: 2)
                    .rotationEffect(.degrees(-8))
                    .offset(x: sweep ? proxy.size.width * 0.95 : -proxy.size.width * 0.95)
                    .blur(radius: 0.5)

                Circle()
                    .stroke(Color.clear, lineWidth: 0)
                    .frame(width: min(proxy.size.width, proxy.size.height) * 0.34)
                    .scaleEffect(sweep ? 1.20 : 0.82)
                    .opacity(sweep ? 0 : 0.9)
            }
            .allowsHitTesting(false)
            .onAppear {
                let duration = max(0.16, 0.40 * appearance.animationDurationMultiplier)
                withAnimation(.easeOut(duration: duration)) { sweep = true }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Shared futuristic page chrome
private struct TechPageChrome<Content: View>: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            content()
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
                .padding(5)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(appearance.resolvedBorderColor.opacity(0.82))
                .frame(width: 88, height: 1.5)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(appearance.resolvedBorderColor.opacity(0.64))
                .frame(width: 88, height: 1.5)
                .allowsHitTesting(false)
        }
        .transition(
            appearance.animationsEnabled
                ? .asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                )
                : .identity
        )
    }
}

// MARK: - Shared futuristic surfaces
struct TechSurface<Content: View>: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let cornerRadius: CGFloat
    @ViewBuilder let content: () -> Content

    init(cornerRadius: CGFloat = 18, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content
    }

    var body: some View {
        content()
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(min(max(appearance.dynamicOpacity, 0.05), 1))
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .techBorder(enabled: appearance.technologyBorderEnabled,
                        color: appearance.resolvedBorderColor,
                        cornerRadius: cornerRadius,
                        width: max(appearance.cardBorderWidth, 1))
    }
}

private struct ActivationCornerMarks: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = min(rect.width, rect.height) * 0.16
        var path = Path()
        // Upper-left corner
        path.move(to: CGPoint(x: 0, y: arm))
        path.addLine(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: arm, y: 0))
        // Lower-right corner
        path.move(to: CGPoint(x: rect.width - arm, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - arm))
        return path
    }
}

private struct LicenseActivationTransitionView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var pulse = false
    @State private var sweep = false
    @State private var coreScale = 0.35

    private var duration: Double {
        max(0.22, 0.72 * appearance.animationDurationMultiplier)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            GeometryReader { proxy in
                let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)

                Circle()
                    .stroke(Color.clear, lineWidth: 0)
                    .frame(width: min(proxy.size.width, proxy.size.height) * 0.72,
                           height: min(proxy.size.width, proxy.size.height) * 0.72)
                    .scaleEffect(pulse ? 1.22 : 0.58)
                    .opacity(pulse ? 0 : 1)
                    .position(center)

                Circle()
                    .fill(RadialGradient(colors: [appearance.resolvedBorderColor.opacity(0.92), .clear],
                                         center: .center, startRadius: 1, endRadius: 120))
                    .frame(width: 240, height: 240)
                    .scaleEffect(coreScale)
                    .position(center)

                Rectangle()
                    .fill(LinearGradient(colors: [.clear, appearance.resolvedBorderColor, .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 2)
                    .shadow(color: appearance.resolvedBorderColor, radius: 14)
                    .offset(y: sweep ? proxy.size.height * 0.45 : -proxy.size.height * 0.45)

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.clear, lineWidth: 0)
                    .frame(width: min(proxy.size.width * 0.72, 520), height: 170)
                    .rotation3DEffect(.degrees(sweep ? 0 : 18), axis: (x: 1, y: 0, z: 0))
                    .scaleEffect(sweep ? 1.04 : 0.86)
                    .opacity(sweep ? 0 : 1)
                    .position(center)

                ActivationCornerMarks()
                    .stroke(appearance.resolvedBorderColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [7, 5]))
                    .frame(width: min(proxy.size.width * 0.72, 520), height: 170)
                    .scaleEffect(sweep ? 1.0 : 0.86)
                    .opacity(sweep ? 1.0 : 0.28)
                    .shadow(color: appearance.resolvedBorderColor.opacity(0.65), radius: 8)
                    .position(center)
            }

            VStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(appearance.resolvedBorderColor)
                    .shadow(color: appearance.resolvedBorderColor.opacity(0.8), radius: 14)
                Text("KEY ĐÃ XÁC THỰC")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(.white)
            }
        }
        .onAppear {
            guard appearance.animationsEnabled else { return }
            withAnimation(.easeOut(duration: duration)) { pulse = true }
            withAnimation(.easeInOut(duration: duration * 0.9)) { sweep = true }
            withAnimation(.spring(response: duration * 0.72, dampingFraction: 0.72)) { coreScale = 1.0 }
        }
    }
}

// MARK: - 12. GridBackgroundView
struct GridBackgroundView: View {
    var spacing:   CGFloat = 25
    var lineWidth: CGFloat = 1
    var lineColor: Color   = Color.white.opacity(0.04)
    var body: some View {
        GeometryReader { g in
            Path { path in
                for x in stride(from: 0, through: g.size.width,  by: spacing) {
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: g.size.height))
                }
                for y in stride(from: 0, through: g.size.height, by: spacing) {
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(Color.clear, lineWidth: 0)
        }
    }
}


private struct FluxHomepageBootstrap: Decodable {
    let adminNotice: FluxHomepageNotice?

    enum CodingKeys: String, CodingKey {
        case adminNotice = "admin_notice"
    }
}

private struct FluxHomepageNotice: Decodable {
    struct ActionButton: Decodable, Identifiable {
        let id: String
        let label: String
        let urlString: String
        let sortOrder: Int

        enum CodingKeys: String, CodingKey {
            case id, label, sortOrder = "sort_order"
            case urlString = "url"
        }

        var url: URL? {
            guard let url = URL(string: urlString), url.scheme?.lowercased() == "https",
                  url.host != nil, url.user == nil, url.password == nil else { return nil }
            return url
        }
    }

    let id: String
    let title: String
    let content: String
    let imageURLString: String
    let buttonLabel: String
    let buttonURLString: String
    let buttons: [ActionButton]
    let enabled: Bool
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, content, enabled, buttons
        case imageURLString = "image_url"
        case buttonLabel = "button_label"
        case buttonURLString = "button_url"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Thông báo"
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        imageURLString = try c.decodeIfPresent(String.self, forKey: .imageURLString) ?? ""
        buttonLabel = try c.decodeIfPresent(String.self, forKey: .buttonLabel) ?? ""
        buttonURLString = try c.decodeIfPresent(String.self, forKey: .buttonURLString) ?? ""
        buttons = (try c.decodeIfPresent([ActionButton].self, forKey: .buttons) ?? []).sorted { $0.sortOrder < $1.sortOrder }
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }

    var imageURL: URL? {
        guard let url = URL(string: imageURLString),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    var buttonURL: URL? {
        guard let url = URL(string: buttonURLString),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

}

private struct FluxHomepageNoticeModal: View {
    let notice: FluxHomepageNotice
    let onDismiss: () -> Void
    let onOpenLink: () -> Void

    // Resolved action list: prefer `buttons` array, fallback to legacy single button
    private var resolvedActions: [FluxHomepageNotice.ActionButton] {
        if !notice.buttons.isEmpty { return notice.buttons.filter { $0.url != nil } }
        guard !notice.buttonLabel.isEmpty else { return [] }
        let legacy = FluxHomepageNotice.ActionButton(
            id: "legacy",
            label: notice.buttonLabel,
            urlString: notice.buttonURLString,
            sortOrder: 0
        )
        return legacy.url != nil ? [legacy] : []
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.52)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            // Modal — auto height theo nội dung, maxWidth 420, padding ngoài 20
            VStack(alignment: .leading, spacing: 0) {

                // ── Header ────────────────────────────────────────────
                HStack(alignment: .center, spacing: 0) {
                    Label("Thông Báo Từ Admin", systemImage: "bolt.fill")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(Color.cyan)
                    Spacer(minLength: 8)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.80))
                            .frame(width: 28, height: 28)
                            .background(
                                Color.white.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Đóng thông báo")
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)

                // ── Image (scaledToFit, cornerRadius 14, maxHeight 200) ──
                if let imageURL = notice.imageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .frame(maxHeight: 200)
                        case .failure:
                            EmptyView()
                        case .empty:
                            ProgressView()
                                .tint(.cyan)
                                .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 80)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.cyan.opacity(0.22), lineWidth: 1)
                    }
                    .shadow(color: Color.cyan.opacity(0.10), radius: 10, y: 3)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }

                // ── Title (bold 18pt, multiline) ──────────────────────
                if !notice.title.isEmpty {
                    Text(notice.title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }

                // ── Content (font 14pt, maxHeight 140) ───────────────
                if !notice.content.isEmpty {
                    ScrollView(showsIndicators: false) {
                        Text(notice.content)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.white.opacity(0.78))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.horizontal, 16)
                    }
                    .frame(maxHeight: 140)
                    .padding(.bottom, 10)
                }

                // ── Buttons: RoundedRectangle(cornerRadius:10), height 38 ──
                // "Đã hiểu" cùng style, không dùng Capsule
                HStack(spacing: 8) {
                    if !resolvedActions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(resolvedActions) { action in
                                    Button {
                                        if let url = action.url { UIApplication.shared.open(url) }
                                    } label: {
                                        HStack(spacing: 5) {
                                            Text(action.label)
                                                .lineLimit(1)
                                                .fixedSize(horizontal: true, vertical: false)
                                            Image(systemName: "arrow.up.right")
                                                .font(.system(size: 10, weight: .bold))
                                        }
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color.black)
                                        .padding(.horizontal, 14)
                                        .frame(height: 38)
                                        .background(
                                            LinearGradient(
                                                colors: [Color.cyan,
                                                         Color(red: 0.20, green: 0.85, blue: 0.78)],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            ),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    Button(action: onDismiss) {
                        Text("Đã hiểu")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 14)
                            .frame(height: 38)
                            .background(
                                Color.cyan.opacity(0.22),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.cyan.opacity(0.60), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Đóng thông báo")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .padding(.top, 2)
            }
            .frame(maxWidth: 420)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.055, green: 0.075, blue: 0.12),
                             Color(red: 0.08, green: 0.12, blue: 0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.cyan.opacity(0.40), lineWidth: 1)
            }
            .shadow(color: Color.cyan.opacity(0.18), radius: 24, y: 10)
            .padding(20)
        }
        .accessibilityAddTraits(.isModal)
    }
}
