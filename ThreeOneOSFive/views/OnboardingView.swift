import SwiftUI

struct OnboardingView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.vietnamese.rawValue
    var onComplete: () -> Void

    private var language: AppLanguage { AppLanguage(rawValue: languageCode) ?? .vietnamese }

    var body: some View {
        ZStack {
            // First launch uses the same dynamic wallpaper system as the main app.
            GlobalBackground()

            VStack(spacing: 0) {
                languagePage
                controls
            }
        }
        .tint(AppTheme.accent)
        .animation(.spring(response: 0.38, dampingFraction: 0.84), value: languageCode)
    }

    // Giao diện chọn ngôn ngữ duy nhất
    private var languagePage: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)
            AppLogo(size: 72)
            VStack(spacing: 8) {
                Text(language.text("onboarding.language_title"))
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(language.text("onboarding.language_subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            VStack(spacing: 10) {
                ForEach(AppLanguage.allCases) { option in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                            languageCode = option.rawValue
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.displayName)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(option.rawValue == "en" ? "English" : option.rawValue == "vi" ? "Tiếng Việt" : "简体中文")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if languageCode == option.rawValue {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(AppTheme.accent)
                                    .font(.title3)
                                    .transition(.scale.combined(with: .opacity))
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary.opacity(0.5))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(uiColor: .secondarySystemBackground))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.clear, lineWidth: 0)
                                )
                        )
                    }
                    .buttonStyle(.plain).techButtonChrome()
                }
            }
            .padding(.horizontal, 20)
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Nút điều khiển: Bấm Hoàn tất là vào app luôn
    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    onComplete()
                }
            } label: {
                Text(language.text("common.finish")) // Nút "Hoàn tất"
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).techButtonChrome()
            .controlSize(.large)
            .padding(.horizontal, 20)

            Text(language.text("onboarding.language_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 16)
        .background(Color(uiColor: .systemBackground).opacity(0.72))
    }
}

// Logic lưu trữ trạng thái khởi động vẫn giữ nguyên để app biết là người dùng đã xem
enum OnboardingStore {
    static let completedVersionKey = "onboarding.completedVersion"
    static let completedFingerprintKey = "onboarding.completedFingerprint"

    static var currentVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }

    static var bundleToken: String {
        if let exe = Bundle.main.executablePath,
           let attrs = try? FileManager.default.attributesOfItem(atPath: exe),
           let date = attrs[.modificationDate] as? Date {
            return String(Int(date.timeIntervalSince1970))
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath),
           let date = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) {
            return String(Int(date.timeIntervalSince1970))
        }
        return "0"
    }

    static var currentFingerprint: String { "\(currentVersion)#\(bundleToken)" }

    static var completedVersion: String? {
        UserDefaults.standard.string(forKey: completedVersionKey)
    }

    static var completedFingerprint: String? {
        UserDefaults.standard.string(forKey: completedFingerprintKey)
    }

    static func shouldShow() -> Bool {
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--skip-onboarding") { return false }
        if ProcessInfo.processInfo.arguments.contains("--reset-onboarding") { return true }
#endif
        let fp = currentFingerprint
        if let stored = completedFingerprint, !stored.isEmpty {
            return stored != fp
        }
        if let completed = completedVersion, !completed.isEmpty {
            if completed == currentVersion {
                UserDefaults.standard.set(fp, forKey: completedFingerprintKey)
                return false
            }
            return true
        }
        return true
    }

    static func markCompleted() {
        UserDefaults.standard.set(currentVersion, forKey: completedVersionKey)
        UserDefaults.standard.set(currentFingerprint, forKey: completedFingerprintKey)
    }
}
