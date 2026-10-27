import SwiftUI
import UIKit
import AVFoundation

// MARK: - FluxCoreAudioPlayer (stream URL, loops forever, survives background)
// Req 3: Exposes isPlaying + stateChangedNotification for music button UI sync
final class FluxCoreAudioPlayer: ObservableObject {
    static let shared = FluxCoreAudioPlayer()
    private static let enabledStorageKey = "audio.background.enabled"
    private static let sourceStorageKey = "audio.background.source"

    enum MusicSource: String, CaseIterable, Identifiable {
        case new = "new"
        case original = "original"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .new: return "Nhạc mới"
            case .original: return "Nhạc gốc"
            }
        }
    }

    /// Notification posted whenever isPlaying changes — observed by FloatingButtonViewController
    static let stateChangedNotification = Notification.Name("FluxCoreAudioPlayerStateChanged")

    private var player: AVPlayer?
    private var loopObserver: Any?

    @Published private(set) var isPlaying: Bool = false

    private let originalMusicURL = URL(string: "https://www.image2url.com/r2/default/audio/1787540835956-e0b3ebb8-d327-4e8e-8b4b-0f19c86a60d3.mp3")!
    private let newMusicURL = URL(string: "https://www.image2url.com/r2/default/videos/1790059572387-f4754000-9359-492e-b1ef-44751ce5ec9d.mp4")!

    @Published private(set) var musicSource: MusicSource {
        didSet { UserDefaults.standard.set(musicSource.rawValue, forKey: Self.sourceStorageKey) }
    }

    private var resolvedMusicURL: URL {
        switch musicSource {
        case .new:
            return newMusicURL
        case .original:
            return AssetPreloadService.cachedURL(key: "audio.background") ?? originalMusicURL
        }
    }

    private init() {
        // Playback itself starts only after the SwiftUI scene is created.
        // The persisted preference is read by shouldPlayOnLaunch.
        let storedSource = UserDefaults.standard.string(forKey: Self.sourceStorageKey)
        musicSource = MusicSource(rawValue: storedSource ?? "") ?? .new
        isPlaying = false
    }

    var shouldPlayOnLaunch: Bool {
        UserDefaults.standard.object(forKey: Self.enabledStorageKey) as? Bool ?? false
    }

    deinit {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
    }

    func play() {
        guard !isPlaying else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)

        if player == nil {
            player = AVPlayer(url: resolvedMusicURL)
            player?.volume = 0.72
        }
        player?.seek(to: .zero)
        player?.play()

        // Loop forever
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.player?.seek(to: .zero)
            self?.player?.play()
        }

        isPlaying = true
        UserDefaults.standard.set(true, forKey: Self.enabledStorageKey)
        NotificationCenter.default.post(name: FluxCoreAudioPlayer.stateChangedNotification, object: nil)
    }

    func setMusicSource(_ source: MusicSource) {
        guard musicSource != source else { return }
        musicSource = source
        if isPlaying {
            stop()
            play()
        } else {
            NotificationCenter.default.post(name: Self.stateChangedNotification, object: nil)
        }
    }

    func toggleMusicSource() {
        setMusicSource(musicSource == .new ? .original : .new)
    }

    func stop() {
        guard isPlaying else { return }
        player?.pause()
        if let obs = loopObserver {
            NotificationCenter.default.removeObserver(obs)
            loopObserver = nil
        }
        isPlaying = false
        UserDefaults.standard.set(false, forKey: Self.enabledStorageKey)
        NotificationCenter.default.post(name: FluxCoreAudioPlayer.stateChangedNotification, object: nil)
    }
}

/// Backward-compatible name used by SettingsView and older UI code.
/// The implementation is the same shared FluxCore audio player.
typealias ZHModzAudioPlayer = FluxCoreAudioPlayer

@main
struct ThreeOneOSFiveApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator()
    @StateObject private var repositoryStore = PackageRepositoryStore()
    @StateObject private var repositoryPatchStore = PatchProjectStore()
    @StateObject private var startupLoader = StartupResourceLoader()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.vietnamese.rawValue
    // Startup loading is intentionally blocking. The existing language onboarding
    // remains available through its store, but must not interrupt the required
    // loading -> license-key flow.
    @State private var showOnboarding = false
    @State private var showAttribution = false
    @State private var updateOffer: AppUpdateChecker.Offer?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        setupLogCapture()
        log("app: FLUXCORE launching — iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName)")
        // Audio playback is deferred until authentication/startup has completed,
        // so the key gate is the first user-facing launch action.
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .vietnamese
    }

    /// Performs the mandatory update gate before StartupResourceLoader is allowed
    /// to preload assets, manifests, or patch packages.
    private func checkMandatoryUpdateGate() async -> Bool {
        let loaded = await AppRuntimeConfig.shared.refresh()
        if !loaded {
            let restored = AppRuntimeConfig.shared.restoreCachedUpdatePolicy()
            if !restored {
                log("update-gate: server unavailable and no cached update policy; continuing in offline-safe mode")
                return false
            }
            log("update-gate: using previously verified cached update policy while offline")
        }

        let currentVersion = AppUpdateChecker.currentVersion
        let minimumVersion = AppRuntimeConfig.shared.updateMinimumVersion
        let belowMinimum = !minimumVersion.isEmpty && AppUpdateChecker.isNewer(minimumVersion, than: currentVersion)
        guard (AppRuntimeConfig.shared.updateEnabled || belowMinimum),
              !(AppRuntimeConfig.shared.updateVersion.isEmpty && minimumVersion.isEmpty) else {
            return false
        }
        let configuredURL = URL(string: AppRuntimeConfig.shared.updateURL)
        let validConfiguredURL = configuredURL.flatMap { url in
            (["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil) ? url : nil
        }
        guard let url = validConfiguredURL ?? (belowMinimum ? AppUpdateChecker.fallbackURL : nil) else { return false }

        updateOffer = AppUpdateChecker.Offer(
            version: AppRuntimeConfig.shared.updateVersion.isEmpty ? minimumVersion : AppRuntimeConfig.shared.updateVersion,
            message: AppRuntimeConfig.shared.updateMessage,
            url: url,
            isMandatory: belowMinimum || AppRuntimeConfig.shared.updatePolicy == "mandatory"
        )
        log("update-gate: update enabled; startup resource loading is blocked")
        return true
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(appState)
                    .environmentObject(patchDraftCoordinator)
                    .environmentObject(fileOperationCoordinator)
                    .environmentObject(repositoryStore)
                    .environmentObject(repositoryPatchStore)
                    .environmentObject(startupLoader)
                    .environment(\.appLanguage, language)
                    .environment(\.locale, language.locale)


            }
            .displayIdentityAttribution(isPresented: $showAttribution, enabled: !showOnboarding)
            .sheet(isPresented: $showAttribution) {
                DisplayAttributionSheet()
            }
            .overlay {
                if let offer = updateOffer {
                    RemoteUpdateModal(offer: offer, onOpen: {
                        UIApplication.shared.open(offer.url)
                    }, onDismiss: { if !offer.isMandatory { updateOffer = nil } })
                }
            }
            .onAppear {
                // Authentication remains the first ContentView gate; this check only
                // fetches the server-managed update notice and never preloads patches.
                appState.detectSupport()
                Task { @MainActor in _ = await checkMandatoryUpdateGate() }
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active, !showOnboarding else { return }
                appState.detectSupport()
            }
            .onOpenURL { url in
                patchDraftCoordinator.presentImport(url)
            }
        }
    }
}


// MARK: - Startup resource gate
//
// This gate owns the launch contract:
// 1. initialize;
// 2. preload the selected anime asset;
// 3. fetch the server patch manifest;
// 4. download/import every active patch;
// 5. expose the main UI only after 100% completion.
//
// Progress is derived from completed real network/cache operations, not a timer.
@MainActor
final class StartupResourceLoader: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var status: String = "Đang khởi tạo APP FLUXCORE..."
    @Published private(set) var detail: String = "Kiểm tra cấu hình ứng dụng"
    @Published private(set) var canSkipFailedPatch = false
    private var started = false

    /// Chỉ bật khi startup thất bại ở bước xác minh/đồng bộ Patch.
    /// Không tự động bỏ qua: người dùng phải bấm nút trong màn hình startup.
    func skipFailedPatch() {
        guard canSkipFailedPatch else { return }
        canSkipFailedPatch = false
        status = "Đã bỏ qua Patch lỗi"
        detail = "Mở giao diện chính mà không nạp Patch chưa sẵn sàng"
        progress = 1.0
    }
    private let patchStore = PatchProjectStore()
    private let patchFetcher = OnlineFileFetcher()

    func start() async -> Bool {
        guard !started else { return progress >= 1 }
        started = true
        // Startup resource loading begins only after successful key authentication.
        // The gate then preloads UI/video assets and synchronizes active patches before
        // the protected application UI is exposed.
        setProgress(
            0.02,
            status: "Đang khởi tạo APP FLUXCORE...",
            detail: "Chuẩn bị bộ nhớ tạm và core engine"
        )

        setProgress(
            0.12,
            status: "Đang tải tài nguyên giao diện...",
            detail: "Đang tải icon và tài nguyên giao diện nhẹ"
        )
        await AssetPreloadService.shared.preloadAll()

        let dynamicAssetResult = await DynamicAssetSyncService.shared.sync()
        if !dynamicAssetResult.failed.isEmpty {
            log("startup-assets: supplemental sync failures=\(dynamicAssetResult.failed.joined(separator: ","))")
        }

        setProgress(
            0.20,
            status: "Đang kiểm tra cấu hình...",
            detail: "Đọc trạng thái bảo trì từ máy chủ"
        )
        _ = await AppRuntimeConfig.shared.refresh()

        if AppRuntimeConfig.shared.appLocked || AppRuntimeConfig.shared.maintenanceMode {
            setProgress(
                1.0,
                status: "Đang ở chế độ bảo trì",
                detail: "Chỉ mở Trang chủ theo cấu hình máy chủ"
            )
            return true
        }

        setProgress(
            0.20,
            status: "Đang kiểm tra Patch...",
            detail: "Đọc và xác minh toàn bộ Patch cục bộ"
        )

        do {
            let localCount = try PatchProjectLibrary.validateAllLocalPackages()
            log("startup-patch: local integrity verified (\(localCount) package(s))")
        } catch {
            log("startup-patch: local integrity failure – \(error.localizedDescription)")
            canSkipFailedPatch = true
            setProgress(
                0.20,
                status: "Patch cục bộ không hợp lệ",
                detail: "Patch lỗi. Bạn có thể bỏ qua Patch để vào ứng dụng."
            )
            return false
        }

        // The launch gate must never treat a failed manifest request as an
        // empty patch set. Retry a few times so transient connectivity does
        // not expose an unverified patch state.
        var manifestReady = false
        for attempt in 1...3 {
            await patchFetcher.fetchServerFiles()
            if patchFetcher.lastFetchSucceeded {
                manifestReady = true
                break
            }
            setProgress(
                0.20,
                status: "Đang kiểm tra Patch (\(attempt)/3)...",
                detail: "Chưa nhận được manifest, đang thử lại"
            )
            if attempt < 3 {
                try? await Task.sleep(for: .milliseconds(600))
            }
        }

        guard manifestReady else {
            log("startup-patch: manifest verification failed after retries")
            canSkipFailedPatch = true
            setProgress(
                0.20,
                status: "Không thể xác minh Patch",
                detail: "Patch chưa xác minh được. Bạn có thể bỏ qua Patch để vào ứng dụng."
            )
            return false
        }

        let files = patchFetcher.onlineFiles

        if files.isEmpty {
            setProgress(
                0.88,
                status: "Đã xác minh Patch",
                detail: "Manifest hợp lệ và không có Patch đang hoạt động"
            )
        } else {
            let synchronized = await patchFetcher.preloadAllPatches(
                files: files,
                store: patchStore,
                progress: { [weak self] completed, total, failed, current in
                    guard let self else { return }
                    let fraction = total > 0 ? Double(completed) / Double(total) : 1
                    let mapped = 0.20 + (fraction * 0.68)
                    let suffix = failed > 0 ? " • \(failed) lỗi" : ""
                    self.setProgress(
                        mapped,
                        status: "Đang đồng bộ Patch \(completed)/\(total)",
                        detail: current.isEmpty ? "Đang kiểm tra dữ liệu cục bộ\(suffix)" : "\(current)\(suffix)"
                    )
                },
                itemResult: { file, ok in
                    log("startup-patch: \(ok ? "ready" : "failed") – \(file.title)")
                }
            )

            guard synchronized else {
                log("startup-patch: synchronization failed or was cancelled")
                canSkipFailedPatch = true
                setProgress(
                    0.88,
                    status: "Patch chưa sẵn sàng",
                    detail: "Patch lỗi hoặc chưa đồng bộ được. Bạn có thể bỏ qua Patch để vào ứng dụng."
                )
                return false
            }

            setProgress(
                0.88,
                status: "Đã đồng bộ Patch",
                detail: "Toàn bộ Patch đang hoạt động đã được xác minh và nhập"
            )
        }

        setProgress(
            0.90,
            status: "Đang chuẩn bị nền...",
            detail: "Cache nền được chọn để mở giao diện nhanh"
        )
        await BackgroundAssetCache.preloadSelectedBackground()

        setProgress(
            0.96,
            status: "Đang hoàn tất môi trường...",
            detail: "Kiểm tra trạng thái cuối cùng của tài nguyên"
        )
        try? await Task.sleep(for: .milliseconds(120))

        setProgress(
            1.0,
            status: "Hoàn tất",
            detail: "Tài nguyên và Patch cần thiết đã sẵn sàng"
        )
        return true
    }

    private func setProgress(_ value: Double, status: String, detail: String) {
        progress = min(max(value, 0), 1)
        self.status = status
        self.detail = detail
    }
}

// MARK: - FLUXCORE Startup Loading UI (REQ 2)
struct StartupLoadingView: View {
    @ObservedObject var loader: StartupResourceLoader
    let onSkipFailedPatch: () -> Void

    private var percent: Int { Int((loader.progress * 100).rounded()) }
    private var isComplete: Bool { loader.progress >= 0.999 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(
                colors: [Color.blue.opacity(0.20), Color.black.opacity(0.96), Color.black],
                center: .center,
                startRadius: 10,
                endRadius: 430
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.12)).frame(width: 178, height: 178).blur(radius: 12)
                    Circle().stroke(Color.white.opacity(0.10), lineWidth: 2).frame(width: 154, height: 154)

                    Circle()
                        .trim(from: 0, to: max(0.001, min(loader.progress, 1)))
                        .stroke(
                            AngularGradient(colors: [.white, .blue, .black, .white], center: .center),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 154, height: 154)
                        .shadow(color: .blue.opacity(0.85), radius: 14)
                        .animation(.linear(duration: 0.18), value: loader.progress)

                    Circle().stroke(Color.blue.opacity(0.25), lineWidth: 1).frame(width: 132, height: 132)
                    AppLogo(size: 86).shadow(color: .blue.opacity(0.65), radius: 18)
                }

                if isComplete {
                    VStack(spacing: 9) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 42, weight: .bold))
                            .foregroundStyle(.green)
                            .shadow(color: .green.opacity(0.75), radius: 12)

                        Text("Truy Cập Thành Công")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("FLUXCORE ZHM")
                            .font(.system(size: 20, weight: .black, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(.white)

                        Text("AN TOÀN - ỔN ĐỊNH - NHANH GỌN")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .tracking(1.0)
                            .foregroundStyle(.white.opacity(0.66))
                    }
                    .padding(.horizontal, 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    VStack(spacing: 8) {
                        Text("\(percent)%")
                            .font(.system(size: 26, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                        Text("FLUXCORE ZHM")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(1.8)
                            .foregroundStyle(.blue.opacity(0.95))
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if isComplete {
                Color.green.opacity(0.08).ignoresSafeArea().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: isComplete)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isComplete ? "Truy Cập Thành Công" : "Đang khởi động FLUXCORE")
        .accessibilityValue("\(percent) phần trăm")
    }
}


// MARK: - Local background cache
enum BackgroundAssetCache {
    private static let staticName = "startup-anime-background-static.mov"
    private static let dynamicName = "startup-anime-background-dynamic.mp4"
    private static let lightSkyName = "startup-light-sky-background.mp4"

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StartupAssets", isDirectory: true)
    }

    static func cachedURL(for key: String) -> URL? {
        if let generic = AssetPreloadService.cachedURL(
            key: {
                switch key {
                case "animeStatic": return "background.static"
                case "animeDynamic": return "background.dynamic"
                case "lightSky": return "background.lightSky"
                default: return key
                }
            }()
        ) {
            return generic
        }
        let name: String
        switch key {
        case "animeStatic":
            name = staticName
        case "animeDynamic":
            name = dynamicName
        case "lightSky":
            name = lightSkyName
        default:
            return nil
        }

        let url = cacheDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func preloadSelectedBackground() async {
        let mode = AppearanceSettings.shared.backgroundMode

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await downloadIfNeeded(
                    urlString: AppearanceSettings.BackgroundMode.animeDynamicVideoURL,
                    fileName: dynamicName
                )
            }
            group.addTask {
                await downloadIfNeeded(
                    urlString: AppearanceSettings.BackgroundMode.lightSkyVideoURL,
                    fileName: lightSkyName
                )
            }

            if mode == .animeStatic {
                group.addTask {
                    await downloadIfNeeded(
                        urlString: AppearanceSettings.BackgroundMode.animeStaticVideoURL,
                        fileName: staticName
                    )
                }
            }

            for await _ in group {}
        }
    }

    private static func downloadIfNeeded(urlString: String, fileName: String) async {
        guard let url = URL(string: urlString) else { return }

        let destination = cacheDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) { return }

        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            configuration.waitsForConnectivity = true

            let (temporaryURL, response) = try await URLSession(configuration: configuration).download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            log("startup-assets: \(error.localizedDescription)")
        }
    }
}

class AppState: ObservableObject {
    @Published var exploitStatus: ExploitStatus = .notStarted
    @Published var unsupportedMessage: String?
    @Published var kernelExploitRunning = false

    private var autoRunAttempted = false

    var kernelExploitApplicable: Bool {
        KernelExploit.isApplicable(
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild
        )
    }

    var isSupported: Bool { unsupportedMessage == nil }

    func detectSupport() {
        let v = AppInfo.versionTuple
        let supported = ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-access") {
            exploitStatus = .success(method: "Simulator preview")
        }
#endif

        unsupportedMessage = supported ? nil : "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))"
        if let unsupportedMessage {
            exploitStatus = .unsupported(unsupportedMessage)
            return
        }

        let applicable = KernelExploit.isApplicable(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
        guard applicable else { return }

        refreshKernelExploitStatus()
        maybeAutoRunKernelExploit()
    }

    private func maybeAutoRunKernelExploit() {
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed,
              !autoRunAttempted else { return }
        autoRunAttempted = true
        log("app: starting kernel exploit automatically")
        runKernelExploitIfNeeded()
    }

    private func refreshKernelExploitStatus() {
        guard !kernelExploitRunning else { return }

        // iOS < 26: kernel R/W success persists (no sandbox probe)
        // iOS >= 26: verify full sandbox escape is still active
        if KernelExploit.requiresSandboxEscape {
            if KernelExploit.hasSandboxAccess() {
                if !exploitStatus.isSuccess {
                    exploitStatus = .success(method: "kexploit")
                    log("app: existing sandbox access is still active; skipping kernel exploit")
                }
            } else if exploitStatus.isSuccess {
                exploitStatus = .notStarted
                log("app: sandbox access is no longer active")
            }
        }
    }

    func runKernelExploitIfNeeded() {
        refreshKernelExploitStatus()
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed else { return }
        kernelExploitRunning = true
        exploitStatus = .notStarted
        log("app: running kernel exploit on background...")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = KernelExploit.run()
            DispatchQueue.main.async {
                self.kernelExploitRunning = false
                if ok {
                    self.exploitStatus = .success(method: "kexploit")
                    if KernelExploit.requiresSandboxEscape {
                        log("app: kernel exploit success — sandbox access verified")
                    } else {
                        log("app: kernel exploit success — kernel access active")
                    }
                } else {
                    self.exploitStatus = .failed(method: "kexploit", code: -1)
                    log("app: kernel exploit failed — relaunch the app before retrying")
                }
            }
        }
    }
}


// MARK: - Remote App Runtime Configuration
struct MaintenanceButton: Codable, Identifiable, Equatable {
    let id: String
    let label: String
    let url: String
}

struct DeveloperInfoLink: Codable, Identifiable {
    let id: String
    let label: String
    let url: String
    let icon: String
    let subtitle: String

    enum CodingKeys: String, CodingKey {
        case id, label, url, icon, subtitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        url = try container.decode(String.self, forKey: .url)
        icon = try container.decode(String.self, forKey: .icon)

        // Backward-compatible with existing developer_info.php payloads that
        // do not yet provide a subtitle field. The UI keeps its existing
        // subtitle row without making the API field mandatory.
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
    }
}

@MainActor
final class DeveloperInfoConfig: ObservableObject {
    static let shared = DeveloperInfoConfig()

    @Published private(set) var name = "FLUXCORE ZHM"
    @Published private(set) var avatarURL: URL?
    @Published private(set) var links: [DeveloperInfoLink] = []

    private init() {}

    func refresh() async {
        guard let url = URL(string: Self.endpoint) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            let payload = try JSONDecoder().decode(Response.self, from: data)
            let cleanName = payload.developer.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanName.isEmpty { name = String(cleanName.prefix(120)) }
            if let rawAvatar = payload.developer.avatarURL, let parsedAvatar = URL(string: rawAvatar), parsedAvatar.scheme?.lowercased() == "https", parsedAvatar.host != nil {
                avatarURL = parsedAvatar
            } else {
                avatarURL = nil
            }
            links = payload.developer.links.filter {
                let scheme = URL(string: $0.url)?.scheme?.lowercased()
                return scheme == "http" || scheme == "https"
            }
        } catch {
            log("developer-info: \(error.localizedDescription)")
        }
    }

    private static let endpoint = "https://appfluxcore.site/api/developer_info.php"

    private struct Response: Decodable { let developer: DeveloperPayload }
    private struct DeveloperPayload: Decodable {
        let name: String
        let avatarURL: String?
        let links: [DeveloperInfoLink]

        enum CodingKeys: String, CodingKey {
            case name, links
            case avatarURL = "avatar_url"
        }
    }
}

@MainActor
final class AppRuntimeConfig: ObservableObject {
    static let shared = AppRuntimeConfig()

    @Published private(set) var maintenanceMode = false
    @Published private(set) var appLocked = false
    @Published private(set) var runtimeStatusMessage = ""
    @Published private(set) var maintenanceNotice = "Hệ thống đang bảo trì, vui lòng quay lại sau."
    @Published private(set) var maintenanceInterval: TimeInterval = 10
    @Published private(set) var maintenanceFontSize: CGFloat = 20
    @Published private(set) var maintenanceButtons: [MaintenanceButton] = []
    @Published private(set) var updateBoxButtonText = "Cập nhật"
    @Published private(set) var updateBoxButtonURL = ""
    @Published private(set) var updateEnabled = false
    @Published private(set) var updateVersion = ""
    @Published private(set) var updateMessage = ""
    @Published private(set) var updateURL = ""
    @Published private(set) var updateMinimumVersion = ""
    @Published private(set) var updatePolicy = "recommended"

    private var refreshTask: URLSessionDataTask?
    private let cachedUpdatePolicyKey = "fluxcore.cached_update_policy.v1"

    private init() {}

    /// Restores only server-validated update fields. Lock/maintenance flags are
    /// intentionally not restored because they can become stale while offline.
    func restoreCachedUpdatePolicy() -> Bool {
        guard let cached = UserDefaults.standard.dictionary(forKey: cachedUpdatePolicyKey) else { return false }
        updateEnabled = cached["enabled"] as? Bool ?? false
        updateVersion = cached["version"] as? String ?? ""
        updateMessage = cached["message"] as? String ?? ""
        updateURL = cached["url"] as? String ?? ""
        updateMinimumVersion = cached["minimum_version"] as? String ?? ""
        updatePolicy = cached["policy"] as? String ?? "recommended"
        return updateEnabled || !updateMinimumVersion.isEmpty
    }

    func refresh() async -> Bool {
        refreshTask?.cancel()
        guard let url = URL(string: Self.endpoint) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return false
            }

            let value = try JSONDecoder().decode(RuntimeValue.self, from: data)

            appLocked = value.appLocked
            maintenanceMode = value.maintenanceMode
            runtimeStatusMessage = value.message
            maintenanceNotice = value.maintenanceMessage
            maintenanceInterval = min(max(TimeInterval(value.maintenanceInterval), 1), 86400)
            maintenanceFontSize = CGFloat(min(max(value.maintenanceFontSize ?? 20, 12), 48))
            maintenanceButtons = (value.maintenanceButtons ?? []).compactMap { item in
                guard !item.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let buttonURL = URL(string: item.url),
                      ["https", "http"].contains(buttonURL.scheme?.lowercased() ?? "") else { return nil }
                return MaintenanceButton(id: item.id, label: String(item.label.prefix(120)), url: item.url)
            }
            updateBoxButtonText = String((value.updateBoxButtonText ?? "Cập nhật").prefix(80))
            updateBoxButtonURL = value.updateBoxButtonURL ?? ""
            updateEnabled = value.updateEnabled
            updateVersion = String(value.updateVersion.prefix(80))
            updateMessage = String(value.updateMessage.prefix(5000))
            updateURL = value.updateURL
            updateMinimumVersion = value.updateMinimumVersion ?? ""
            updatePolicy = value.updatePolicy ?? "recommended"
            UserDefaults.standard.set([
                "enabled": updateEnabled,
                "version": updateVersion,
                "message": updateMessage,
                "url": updateURL,
                "minimum_version": updateMinimumVersion,
                "policy": updatePolicy
            ], forKey: cachedUpdatePolicyKey)

            return true
        } catch is CancellationError {
            return false
        } catch {
            log("runtime-config: \(error.localizedDescription)")
            return false
        }
    }

    private static let endpoint = "https://appfluxcore.site/api/fluxcore_status.php?app=fluxcore"

    private struct RuntimeValue: Decodable {
        let appLocked: Bool
        let maintenanceMode: Bool
        let message: String
        let maintenanceMessage: String
        let maintenanceInterval: Int
        let statusApiEnabled: Bool
        let updateEnabled: Bool
        let updateVersion: String
        let updateMessage: String
        let updateURL: String
        let updateMinimumVersion: String?
        let updatePolicy: String?
        let maintenanceFontSize: Double?
        let maintenanceButtons: [RuntimeButton]?
        let updateBoxButtonText: String?
        let updateBoxButtonURL: String?

        struct RuntimeButton: Decodable {
            let id: String
            let label: String
            let url: String
        }

        enum CodingKeys: String, CodingKey {
            case appLocked = "app_locked"
            case maintenanceMode = "maintenance_mode"
            case message
            case maintenanceMessage = "maintenance_message"
            case maintenanceInterval = "maintenance_interval"
            case statusApiEnabled = "status_api_enabled"
            case updateEnabled = "update_enabled"
            case updateVersion = "update_version"
            case updateMessage = "update_message"
            case updateURL = "update_url"
            case updateMinimumVersion = "update_minimum_version"
            case updatePolicy = "update_policy"
            case maintenanceFontSize = "maintenance_font_size"
            case maintenanceButtons = "maintenance_buttons"
            case updateBoxButtonText = "update_box_button_text"
            case updateBoxButtonURL = "update_box_button_url"
        }
    }

}
