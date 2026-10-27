import SwiftUI
import AVKit
import AVFoundation
import ImageIO

// MARK: - Patch function visual settings
/// User-facing intensity for MOD/HOLO/AIM/MENU controls.
/// This affects the visual emphasis of the function controls only; it never
/// changes the underlying patch bytes or the patch transaction state.
final class PatchFunctionSettings: ObservableObject {
    static let shared = PatchFunctionSettings()

    private enum Key {
        static let aim = "PatchFunctionSettings.aimOpacity.v2"
        static let holo = "PatchFunctionSettings.holoOpacity.v2"
        static let mod = "PatchFunctionSettings.modOpacity.v2"
        static let menu = "PatchFunctionSettings.menuOpacity.v1"
        static let legacyAim = "PatchFunctionSettings.aimOpacity.v1"
        static let legacyHolo = "PatchFunctionSettings.holoOpacity.v1"
        static let legacyMod = "PatchFunctionSettings.modOpacity.v1"
        static let aimColor = "PatchFunctionSettings.aimColorHex.v1"
        static let holoColor = "PatchFunctionSettings.holoColorHex.v1"
        static let modColor = "PatchFunctionSettings.modColorHex.v1"
        static let menuColor = "PatchFunctionSettings.menuColorHex.v1"
    }

    @Published var aimOpacity: Double {
        didSet { UserDefaults.standard.set(Self.normalized(aimOpacity), forKey: Key.aim) }
    }

    @Published var holoOpacity: Double {
        didSet { UserDefaults.standard.set(Self.normalized(holoOpacity), forKey: Key.holo) }
    }

    @Published var modOpacity: Double {
        didSet { UserDefaults.standard.set(Self.normalized(modOpacity), forKey: Key.mod) }
    }

    @Published var menuOpacity: Double {
        didSet { UserDefaults.standard.set(Self.normalized(menuOpacity), forKey: Key.menu) }
    }

    @Published var menuColorHex: String {
        didSet { UserDefaults.standard.set(Self.normalizedHex(menuColorHex, fallback: "#00F0FF"), forKey: Key.menuColor) }
    }

    @Published var aimColorHex: String {
        didSet { UserDefaults.standard.set(Self.normalizedHex(aimColorHex, fallback: "#FF3838"), forKey: Key.aimColor) }
    }

    @Published var holoColorHex: String {
        didSet { UserDefaults.standard.set(Self.normalizedHex(holoColorHex, fallback: "#14D1FF"), forKey: Key.holoColor) }
    }

    @Published var modColorHex: String {
        didSet { UserDefaults.standard.set(Self.normalizedHex(modColorHex, fallback: "#9E47FF"), forKey: Key.modColor) }
    }

    private init() {
        let defaults = UserDefaults.standard
        aimOpacity = Self.normalized(
            defaults.object(forKey: Key.aim) as? Double
                ?? defaults.object(forKey: Key.legacyAim) as? Double
                ?? 1.0
        )
        holoOpacity = Self.normalized(
            defaults.object(forKey: Key.holo) as? Double
                ?? defaults.object(forKey: Key.legacyHolo) as? Double
                ?? 1.0
        )
        modOpacity = Self.normalized(
            defaults.object(forKey: Key.mod) as? Double
                ?? defaults.object(forKey: Key.legacyMod) as? Double
                ?? 1.0
        )
        menuOpacity = Self.normalized(defaults.object(forKey: Key.menu) as? Double ?? 1.0)
        menuColorHex = Self.normalizedHex(defaults.string(forKey: Key.menuColor), fallback: "#00F0FF")
        aimColorHex = Self.normalizedHex(defaults.string(forKey: Key.aimColor), fallback: "#FF3838")
        holoColorHex = Self.normalizedHex(defaults.string(forKey: Key.holoColor), fallback: "#14D1FF")
        modColorHex = Self.normalizedHex(defaults.string(forKey: Key.modColor), fallback: "#9E47FF")
    }

    func opacity(for type: PatchType) -> Double {
        switch type {
        case .aim: return Self.normalized(aimOpacity)
        case .holo: return Self.normalized(holoOpacity)
        case .mod: return Self.normalized(modOpacity)
        case .menu: return Self.normalized(menuOpacity)
        }
    }

    func color(for type: PatchType) -> Color {
        let hex: String
        switch type {
        case .aim: hex = aimColorHex
        case .holo: hex = holoColorHex
        case .mod: hex = modColorHex
        case .menu: hex = menuColorHex
        }
        return Color(hex: hex) ?? Color(red: 0.08, green: 0.62, blue: 1.0)
    }

    func setColor(_ color: Color, for type: PatchType) {
        switch type {
        case .aim: aimColorHex = color.hexString
        case .holo: holoColorHex = color.hexString
        case .mod: modColorHex = color.hexString
        case .menu: menuColorHex = color.hexString
        }
    }

    private static func normalized(_ value: Double) -> Double {
        min(max(value, 0.10), 1.0)
    }

    private static func normalizedHex(_ value: String?, fallback: String) -> String {
        guard let value = value else { return fallback }
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !hex.hasPrefix("#") { hex = "#\(hex)" }
        let digits = "0123456789ABCDEF"
        guard hex.count == 7,
              hex.dropFirst().allSatisfy({ digits.contains($0) }) else {
            return fallback
        }
        return hex
    }
}

// MARK: - AppearanceSettings
extension Notification.Name {
    static let fluxCoreAutoDisableSettingsChanged = Notification.Name("fluxcore.autoDisableSettingsChanged")
    /// Posted by KeyAuthManager khi web dashboard thay đổi trạng thái patch.
    /// userInfo["enabled"]: Bool — true = web cho phép patch, false = web khóa patch.
    static let fluxCoreWebPatchToggled = Notification.Name("fluxcore.webPatchToggled")
    /// Posted khi web dashboard tắt riêng lẻ một số patch cụ thể.
    /// userInfo["patch_ids"]: [String] — danh sách server patch ID bị tắt.
    static let fluxCoreWebPatchIDsDisabled = Notification.Name("fluxcore.webPatchIDsDisabled")
    /// Posted khi web dashboard bật lại một số patch cụ thể.
    /// userInfo["patch_ids"]: [String] — danh sách server patch ID được bật lại.
    static let fluxCoreWebPatchIDsEnabled = Notification.Name("fluxcore.webPatchIDsEnabled")
}

final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()

    typealias AutoDisableConfiguration = AutoDisablePatchPolicy

    /// Dynamic Transparency is published explicitly so every view observing this
    /// shared settings object redraws immediately when the slider changes.
    @Published var dynamicOpacity: Double {
        didSet {
            let normalized = min(max(dynamicOpacity, 0.05), 1.0)
            if normalized != dynamicOpacity {
                dynamicOpacity = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "appearance.dynamicOpacity")
        }
    }

    @Published var borderStyle: BorderStyle {
        didSet { UserDefaults.standard.set(borderStyle.rawValue, forKey: "appearance.borderStyle") }
    }
    @Published var borderColorHex: String {
        didSet { UserDefaults.standard.set(borderColorHex, forKey: "appearance.borderColor") }
    }
    @Published var colorSchemeMode: ColorSchemeMode {
        didSet { UserDefaults.standard.set(colorSchemeMode.rawValue, forKey: "appearance.colorScheme") }
    }

    /// Two-mode product theme: futuristic dark or polished default light.
    @Published var appThemeMode: AppThemeMode {
        didSet { UserDefaults.standard.set(appThemeMode.rawValue, forKey: "appearance.appThemeMode") }
    }
    @Published var backgroundMode: BackgroundMode {
        didSet { UserDefaults.standard.set(backgroundMode.rawValue, forKey: "appearance.bgMode") }
    }

    @Published var cardCornerRadius: Double {
        didSet { UserDefaults.standard.set(cardCornerRadius, forKey: "appearance.cardCornerRadius") }
    }
    @Published var cardFillOpacity: Double {
        didSet { UserDefaults.standard.set(cardFillOpacity, forKey: "appearance.cardFillOpacity") }
    }
    @Published var cardBorderOpacity: Double {
        didSet { UserDefaults.standard.set(cardBorderOpacity, forKey: "appearance.cardBorderOpacity") }
    }
    @Published var cardBorderWidth: Double {
        didSet { UserDefaults.standard.set(cardBorderWidth, forKey: "appearance.cardBorderWidth") }
    }

    /// Controls the shape of application cards/buttons across the patch UI.
    @Published var appButtonStyle: AppButtonStyle {
        didSet { UserDefaults.standard.set(appButtonStyle.rawValue, forKey: "appearance.appButtonStyle") }
    }

    /// Dedicated global accent used by application buttons and their borders.
    @Published var appButtonColorHex: String {
        didSet { UserDefaults.standard.set(appButtonColorHex, forKey: "appearance.appButtonColorHex") }
    }

    /// Dedicated border controls for the primary “MỞ APP” action.
    /// Kept separate from global/card borders so this button can be tuned
    /// without changing unrelated components.
    @Published var appButtonBorderEnabled: Bool {
        didSet { UserDefaults.standard.set(appButtonBorderEnabled, forKey: "appearance.appButtonBorderEnabled") }
    }

    @Published var appButtonBorderColorHex: String {
        didSet { UserDefaults.standard.set(appButtonBorderColorHex, forKey: "appearance.appButtonBorderColorHex") }
    }

    @Published var appButtonBorderOpacity: Double {
        didSet {
            let normalized = min(max(appButtonBorderOpacity, 0), 1)
            if normalized != appButtonBorderOpacity {
                appButtonBorderOpacity = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "appearance.appButtonBorderOpacity")
        }
    }

    @Published var appButtonBorderWidth: Double {
        didSet {
            let normalized = min(max(appButtonBorderWidth, 0), 4)
            if normalized != appButtonBorderWidth {
                appButtonBorderWidth = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "appearance.appButtonBorderWidth")
        }
    }

    /// Opacity/intensity of the AIM/HOLO/MOD page selector itself.
    @Published var functionSelectorOpacity: Double {
        didSet {
            let normalized = min(max(functionSelectorOpacity, 0.10), 1.0)
            if normalized != functionSelectorOpacity {
                functionSelectorOpacity = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "appearance.functionSelectorOpacity")
        }
    }

    /// Corner radius dedicated to the AIM / HOLO / MOD selector.
    /// This is intentionally independent from the global button style so the
    /// three function channels remain rounded even when other app buttons use
    /// the square style.
    @Published var functionSelectorCornerRadius: Double {
        didSet {
            let normalized = min(max(functionSelectorCornerRadius, 8), 36)
            if normalized != functionSelectorCornerRadius {
                functionSelectorCornerRadius = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "appearance.functionSelectorCornerRadius")
        }
    }

    /// Global component controls. Shared views read these values directly so
    /// changes propagate in real time without rebuilding the navigation model.
    @Published var globalOpacity: Double {
        didSet { UserDefaults.standard.set(globalOpacity, forKey: "appearance.globalOpacity") }
    }

    @Published var strokeWidth: Double {
        didSet { UserDefaults.standard.set(strokeWidth, forKey: "appearance.strokeWidth") }
    }

    @Published var globalAccentHex: String {
        didSet { UserDefaults.standard.set(globalAccentHex, forKey: "appearance.globalAccentHex") }
    }

    @Published var fontWeight: FontWeight {
        didSet { UserDefaults.standard.set(fontWeight.rawValue, forKey: "appearance.fontWeight") }
    }

    @Published var functionScale: Double {
        didSet { UserDefaults.standard.set(functionScale, forKey: "appearance.functionScale") }
    }

    // MARK: Advanced interaction / animation controls
    @Published var animationsEnabled: Bool {
        didSet { UserDefaults.standard.set(animationsEnabled, forKey: "appearance.animationsEnabled") }
    }

    /// 0.50 = slower/softer, 1.00 = default, 1.50 = faster.
    @Published var animationSpeed: Double {
        didSet {
            let normalized = min(max(animationSpeed, 0.50), 1.50)
            if normalized != animationSpeed {
                animationSpeed = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "appearance.animationSpeed")
        }
    }

    @Published var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: "appearance.hapticsEnabled") }
    }

    /// Automatically restores a patch after it has been enabled for the configured delay.
    /// This is a presentation/interaction setting; the actual restore still goes through
    /// PatchToggleStore and DevicePatchService so transaction safety is preserved.
    @Published var autoDisablePatches: Bool {
        didSet {
            UserDefaults.standard.set(autoDisablePatches, forKey: "appearance.autoDisablePatches")
            NotificationCenter.default.post(name: .fluxCoreAutoDisableSettingsChanged, object: nil)
        }
    }

    /// When enabled, disabling a patch removes only the patch target files recorded
    /// by the transaction journal instead of writing backup bytes over them.
    @Published var accountProtectionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(accountProtectionEnabled, forKey: "appearance.accountProtectionEnabled")
        }
    }

    /// Delay in seconds before an enabled patch is automatically restored.
    /// Technical default: exactly 8 seconds. Keep this value centralized so UI
    /// and patch scheduling cannot drift to different timeout values.
    @Published var autoDisablePatchSeconds: Double {
        didSet {
            let normalized = min(max(autoDisablePatchSeconds, 1), 20)
            if normalized != autoDisablePatchSeconds {
                autoDisablePatchSeconds = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "appearance.autoDisablePatchSeconds")
            NotificationCenter.default.post(name: .fluxCoreAutoDisableSettingsChanged, object: nil)
        }
    }

    /// Visual configuration for the live patch countdown badge.
    @Published var patchCountdownColorHex: String {
        didSet { UserDefaults.standard.set(Self.normalizedHex(patchCountdownColorHex, fallback: "#2E85FF"), forKey: "appearance.patchCountdownColorHex") }
    }

    @Published var patchCountdownFontWeight: FontWeight {
        didSet { UserDefaults.standard.set(patchCountdownFontWeight.rawValue, forKey: "appearance.patchCountdownFontWeight") }
    }

    @Published var patchCountdownOpacity: Double {
        didSet {
            let normalized = min(max(patchCountdownOpacity, 0.10), 1.0)
            if normalized != patchCountdownOpacity {
                patchCountdownOpacity = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "appearance.patchCountdownOpacity")
        }
    }

    // Per-component button appearance. Existing functionality is untouched;
    // these values only control presentation.
    @Published var buttonOpacity: Double {
        didSet { UserDefaults.standard.set(buttonOpacity, forKey: "appearance.buttonOpacity") }
    }
    @Published var buttonBorderOpacity: Double {
        didSet { UserDefaults.standard.set(buttonBorderOpacity, forKey: "appearance.buttonBorderOpacity") }
    }
    @Published var buttonBorderWidth: Double {
        didSet { UserDefaults.standard.set(buttonBorderWidth, forKey: "appearance.buttonBorderWidth") }
    }
    @Published var buttonCornerRadius: Double {
        didSet { UserDefaults.standard.set(buttonCornerRadius, forKey: "appearance.buttonCornerRadius") }
    }


    // Shared button glow controls. These are presentation-only and persist immediately.
    @Published var buttonGlowEnabled: Bool {
        didSet { UserDefaults.standard.set(buttonGlowEnabled, forKey: "appearance.buttonGlowEnabled") }
    }
    @Published var buttonGlowColorHex: String {
        didSet { UserDefaults.standard.set(Self.normalizedHex(buttonGlowColorHex, fallback: "#2E85FF"), forKey: "appearance.buttonGlowColorHex") }
    }
    @Published var buttonGlowIntensity: Double {
        didSet {
            let normalized = min(max(buttonGlowIntensity, 0), 1)
            if normalized != buttonGlowIntensity {
                buttonGlowIntensity = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "appearance.buttonGlowIntensity")
        }
    }
    @Published var buttonGlowRadius: Double {
        didSet {
            let normalized = min(max(buttonGlowRadius, 0), 24)
            if normalized != buttonGlowRadius {
                buttonGlowRadius = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "appearance.buttonGlowRadius")
        }
    }
    @Published var buttonGlassOpacity: Double {
        didSet {
            let normalized = min(max(buttonGlassOpacity, 0), 0.55)
            if normalized != buttonGlassOpacity {
                buttonGlassOpacity = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "appearance.buttonGlassOpacity")
        }
    }

    // Dedicated Mở App glow controls so the primary action can be tuned independently.
    @Published var appButtonGlowEnabled: Bool {
        didSet { UserDefaults.standard.set(appButtonGlowEnabled, forKey: "appearance.appButtonGlowEnabled") }
    }
    @Published var appButtonGlowColorHex: String {
        didSet { UserDefaults.standard.set(Self.normalizedHex(appButtonGlowColorHex, fallback: "#2E85FF"), forKey: "appearance.appButtonGlowColorHex") }
    }
    @Published var appButtonGlowIntensity: Double {
        didSet {
            let normalized = min(max(appButtonGlowIntensity, 0), 1)
            if normalized != appButtonGlowIntensity {
                appButtonGlowIntensity = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "appearance.appButtonGlowIntensity")
        }
    }
    @Published var appButtonGlowRadius: Double {
        didSet {
            let normalized = min(max(appButtonGlowRadius, 0), 28)
            if normalized != appButtonGlowRadius {
                appButtonGlowRadius = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "appearance.appButtonGlowRadius")
        }
    }

    // Developer Info has its own controls so it can be tuned independently.
    @Published var developerInfoOpacity: Double {
        didSet { UserDefaults.standard.set(developerInfoOpacity, forKey: "appearance.developerInfoOpacity") }
    }
    @Published var developerInfoBorderOpacity: Double {
        didSet { UserDefaults.standard.set(developerInfoBorderOpacity, forKey: "appearance.developerInfoBorderOpacity") }
    }
    @Published var developerInfoBorderWidth: Double {
        didSet { UserDefaults.standard.set(developerInfoBorderWidth, forKey: "appearance.developerInfoBorderWidth") }
    }

    @Published var technologyBorderEnabled: Bool {
        didSet { UserDefaults.standard.set(technologyBorderEnabled, forKey: "appearance.technologyBorderEnabled") }
    }

    var animationDurationMultiplier: Double {
        animationsEnabled ? (1.0 / animationSpeed) : 0.001
    }

    // MARK: License-key login appearance
    @Published var keyLoginBorderStyle: BorderStyle {
        didSet { UserDefaults.standard.set(keyLoginBorderStyle.rawValue, forKey: "appearance.keyLoginBorderStyle") }
    }

    @Published var keyLoginBorderColorHex: String {
        didSet { UserDefaults.standard.set(keyLoginBorderColorHex, forKey: "appearance.keyLoginBorderColorHex") }
    }

    @Published var keyLoginBackgroundHex: String {
        didSet { UserDefaults.standard.set(keyLoginBackgroundHex, forKey: "appearance.keyLoginBackgroundHex") }
    }

    @Published var keyLoginBackgroundOpacity: Double {
        didSet {
            let normalized = min(max(keyLoginBackgroundOpacity, 0.05), 1.0)
            if normalized != keyLoginBackgroundOpacity {
                keyLoginBackgroundOpacity = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "appearance.keyLoginBackgroundOpacity")
        }
    }

    @Published var keyLoginBorderWidth: Double {
        didSet {
            let normalized = min(max(keyLoginBorderWidth, 0), 4)
            if normalized != keyLoginBorderWidth {
                keyLoginBorderWidth = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "appearance.keyLoginBorderWidth")
        }
    }

    @Published var keyLoginCornerRadius: Double {
        didSet {
            let normalized = min(max(keyLoginCornerRadius, 12), 36)
            if normalized != keyLoginCornerRadius {
                keyLoginCornerRadius = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: "appearance.keyLoginCornerRadius")
        }
    }

    var resolvedKeyLoginBorderColor: Color {
        Color(hex: keyLoginBorderColorHex) ?? resolvedBorderColor
    }

    var resolvedKeyLoginBackgroundColor: Color {
        Color(hex: keyLoginBackgroundHex) ?? Color.black
    }

    func resetAppearanceOnly() {
        dynamicOpacity = 0.40
        colorSchemeMode = .light
        appThemeMode = .default
        backgroundMode = .light
        borderStyle = .transparent
        borderColorHex = "#2F85FF"
        cardCornerRadius = 24
        cardFillOpacity = 0.42
        cardBorderOpacity = 0.55
        cardBorderWidth = 1.0
        appButtonStyle = .futuristic
        appButtonColorHex = "#0A84FF"
        appButtonBorderEnabled = true
        appButtonBorderColorHex = "#0A84FF"
        appButtonBorderOpacity = 0.78
        appButtonBorderWidth = 1.25
        functionSelectorOpacity = 0.92
        functionSelectorCornerRadius = 18
        globalOpacity = 1.0
        strokeWidth = 1.0
        globalAccentHex = "#2E85FF"
        fontWeight = .semibold
        functionScale = 0.88
        buttonOpacity = 1.0
        buttonBorderOpacity = 0.55
        buttonBorderWidth = 1.0
        buttonCornerRadius = 14
        buttonGlowEnabled = true
        buttonGlowColorHex = "#2E85FF"
        buttonGlowIntensity = 0.62
        buttonGlowRadius = 10
        buttonGlassOpacity = 0.18
        appButtonGlowEnabled = true
        appButtonGlowColorHex = "#2E85FF"
        appButtonGlowIntensity = 0.78
        appButtonGlowRadius = 16
        developerInfoOpacity = 0.40
        developerInfoBorderOpacity = 0.30
        developerInfoBorderWidth = 1.0
        technologyBorderEnabled = true
        animationsEnabled = true
        animationSpeed = 1.0
        hapticsEnabled = true
        autoDisablePatches = AutoDisableConfiguration.defaultEnabled
        autoDisablePatchSeconds = AutoDisableConfiguration.defaultTimeoutSeconds
        patchCountdownColorHex = "#2E85FF"
        patchCountdownFontWeight = .bold
        patchCountdownOpacity = 1.0
        keyLoginBorderStyle = .colored
        keyLoginBorderColorHex = "#56606D"
        keyLoginBackgroundHex = "#05070D"
        keyLoginBackgroundOpacity = 0.96
        keyLoginBorderWidth = 1.10
        keyLoginCornerRadius = 20

        // Reset the FFM / FFTH AIM / HOLO / MOD visual controls as well.
        let functionSettings = PatchFunctionSettings.shared
        functionSettings.aimOpacity = 1.0
        functionSettings.holoOpacity = 1.0
        functionSettings.modOpacity = 1.0
        functionSettings.menuOpacity = 1.0
        functionSettings.aimColorHex = "#FF3838"
        functionSettings.holoColorHex = "#14D1FF"
        functionSettings.modColorHex = "#9E47FF"
        functionSettings.menuColorHex = "#00F0FF"
    }

    private init() {
        let defaults = UserDefaults.standard
        let appearanceHasInitialized = defaults.bool(forKey: "appearance.initialized.v1")

        // Fresh installs start in the dark/futuristic presentation.
        // Existing installations keep their explicitly saved appearance.
        if !appearanceHasInitialized {
            defaults.set(ColorSchemeMode.dark.rawValue, forKey: "appearance.colorScheme")
            defaults.set(AppThemeMode.futuristic.rawValue, forKey: "appearance.appThemeMode")
            defaults.set(BackgroundMode.dark.rawValue, forKey: "appearance.bgMode")
            defaults.set(true, forKey: "appearance.initialized.v1")
        }

        dynamicOpacity = min(max(defaults.object(forKey: "appearance.dynamicOpacity") as? Double ?? 0.4, 0.05), 1.0)
        borderStyle = BorderStyle(rawValue: defaults.string(forKey: "appearance.borderStyle") ?? "") ?? .transparent
        borderColorHex = defaults.string(forKey: "appearance.borderColor") ?? "#2F85FF"
        colorSchemeMode = ColorSchemeMode(rawValue: defaults.string(forKey: "appearance.colorScheme") ?? "") ?? .light
        appThemeMode = AppThemeMode(rawValue: defaults.string(forKey: "appearance.appThemeMode") ?? "") ?? .default
        backgroundMode = BackgroundMode(rawValue: defaults.string(forKey: "appearance.bgMode") ?? "") ?? .light
        cardCornerRadius = min(max(defaults.object(forKey: "appearance.cardCornerRadius") as? Double ?? 24, 12), 36)
        cardFillOpacity = min(max(defaults.object(forKey: "appearance.cardFillOpacity") as? Double ?? 0.42, 0.05), 0.95)
        cardBorderOpacity = min(max(defaults.object(forKey: "appearance.cardBorderOpacity") as? Double ?? 0.55, 0.0), 1.0)
        cardBorderWidth = min(max(defaults.object(forKey: "appearance.cardBorderWidth") as? Double ?? 1.0, 0.0), 3.0)
        appButtonStyle = AppButtonStyle(
            rawValue: defaults.string(forKey: "appearance.appButtonStyle") ?? AppButtonStyle.futuristic.rawValue
        ) ?? .futuristic
        appButtonColorHex = defaults.string(forKey: "appearance.appButtonColorHex") ?? "#0A84FF"
        appButtonBorderEnabled = defaults.object(forKey: "appearance.appButtonBorderEnabled") as? Bool ?? true
        appButtonBorderColorHex = defaults.string(forKey: "appearance.appButtonBorderColorHex") ?? "#0A84FF"
        appButtonBorderOpacity = min(max(defaults.object(forKey: "appearance.appButtonBorderOpacity") as? Double ?? 0.78, 0), 1)
        appButtonBorderWidth = min(max(defaults.object(forKey: "appearance.appButtonBorderWidth") as? Double ?? 1.10, 0), 4)
        functionSelectorOpacity = min(
            max(defaults.object(forKey: "appearance.functionSelectorOpacity") as? Double ?? 0.92, 0.10),
            1.0
        )
        functionSelectorCornerRadius = min(
            max(defaults.object(forKey: "appearance.functionSelectorCornerRadius") as? Double ?? 18, 8),
            36
        )
        globalOpacity = min(max(defaults.object(forKey: "appearance.globalOpacity") as? Double ?? 1.0, 0.35), 1.0)
        strokeWidth = min(max(defaults.object(forKey: "appearance.strokeWidth") as? Double ?? 1.0, 0.0), 4.0)
        globalAccentHex = defaults.string(forKey: "appearance.globalAccentHex") ?? "#2E85FF"
        fontWeight = FontWeight(rawValue: defaults.string(forKey: "appearance.fontWeight") ?? "") ?? .semibold
        functionScale = min(max(defaults.object(forKey: "appearance.functionScale") as? Double ?? 0.88, 0.70), 1.15)
        animationsEnabled = defaults.object(forKey: "appearance.animationsEnabled") as? Bool ?? false
        animationSpeed = min(max(defaults.object(forKey: "appearance.animationSpeed") as? Double ?? 1.0, 0.50), 1.50)
        hapticsEnabled = defaults.object(forKey: "appearance.hapticsEnabled") as? Bool ?? false
        autoDisablePatches = defaults.object(forKey: "appearance.autoDisablePatches") as? Bool ?? AutoDisableConfiguration.defaultEnabled
        accountProtectionEnabled = defaults.object(forKey: "appearance.accountProtectionEnabled") as? Bool ?? false
        autoDisablePatchSeconds = min(max(defaults.object(forKey: "appearance.autoDisablePatchSeconds") as? Double ?? AutoDisableConfiguration.defaultTimeoutSeconds, 1), 20)
        patchCountdownColorHex = Self.normalizedHex(defaults.string(forKey: "appearance.patchCountdownColorHex"), fallback: "#2E85FF")
        patchCountdownFontWeight = FontWeight(rawValue: defaults.string(forKey: "appearance.patchCountdownFontWeight") ?? "") ?? .bold
        patchCountdownOpacity = min(max(defaults.object(forKey: "appearance.patchCountdownOpacity") as? Double ?? 1.0, 0.10), 1.0)
        keyLoginBorderStyle = BorderStyle(rawValue: defaults.string(forKey: "appearance.keyLoginBorderStyle") ?? "") ?? .colored
        keyLoginBorderColorHex = defaults.string(forKey: "appearance.keyLoginBorderColorHex") ?? "#56606D"
        keyLoginBackgroundHex = defaults.string(forKey: "appearance.keyLoginBackgroundHex") ?? "#05070D"
        keyLoginBackgroundOpacity = min(max(defaults.object(forKey: "appearance.keyLoginBackgroundOpacity") as? Double ?? 0.96, 0.05), 1.0)
        keyLoginBorderWidth = min(max(defaults.object(forKey: "appearance.keyLoginBorderWidth") as? Double ?? 1.10, 0), 4)
        keyLoginCornerRadius = min(max(defaults.object(forKey: "appearance.keyLoginCornerRadius") as? Double ?? 20, 12), 36)
        buttonOpacity = min(max(defaults.object(forKey: "appearance.buttonOpacity") as? Double ?? 1.0, 0.20), 1.0)
        buttonBorderOpacity = min(max(defaults.object(forKey: "appearance.buttonBorderOpacity") as? Double ?? 0.55, 0.0), 1.0)
        buttonBorderWidth = min(max(defaults.object(forKey: "appearance.buttonBorderWidth") as? Double ?? 1.0, 0.0), 4.0)
        buttonCornerRadius = min(max(defaults.object(forKey: "appearance.buttonCornerRadius") as? Double ?? 14, 0), 30)
        buttonGlowEnabled = defaults.object(forKey: "appearance.buttonGlowEnabled") as? Bool ?? true
        buttonGlowColorHex = Self.normalizedHex(defaults.string(forKey: "appearance.buttonGlowColorHex"), fallback: "#2E85FF")
        buttonGlowIntensity = min(max(defaults.object(forKey: "appearance.buttonGlowIntensity") as? Double ?? 0.62, 0), 1)
        buttonGlowRadius = min(max(defaults.object(forKey: "appearance.buttonGlowRadius") as? Double ?? 10, 0), 24)
        buttonGlassOpacity = min(max(defaults.object(forKey: "appearance.buttonGlassOpacity") as? Double ?? 0.18, 0), 0.55)
        appButtonGlowEnabled = defaults.object(forKey: "appearance.appButtonGlowEnabled") as? Bool ?? true
        appButtonGlowColorHex = Self.normalizedHex(defaults.string(forKey: "appearance.appButtonGlowColorHex"), fallback: "#2E85FF")
        appButtonGlowIntensity = min(max(defaults.object(forKey: "appearance.appButtonGlowIntensity") as? Double ?? 0.78, 0), 1)
        appButtonGlowRadius = min(max(defaults.object(forKey: "appearance.appButtonGlowRadius") as? Double ?? 16, 0), 28)
        developerInfoOpacity = min(max(defaults.object(forKey: "appearance.developerInfoOpacity") as? Double ?? 0.40, 0.05), 1.0)
        developerInfoBorderOpacity = min(max(defaults.object(forKey: "appearance.developerInfoBorderOpacity") as? Double ?? 0.30, 0.0), 1.0)
        developerInfoBorderWidth = min(max(defaults.object(forKey: "appearance.developerInfoBorderWidth") as? Double ?? 1.0, 0.0), 4.0)
        technologyBorderEnabled = defaults.object(forKey: "appearance.technologyBorderEnabled") as? Bool ?? false
    }

    enum FontWeight: String, CaseIterable, Identifiable {
        case regular, medium, semibold, bold
        var id: String { rawValue }
        var label: String {
            switch self {
            case .regular: return "Mảnh"
            case .medium: return "Vừa"
            case .semibold: return "Đậm"
            case .bold: return "Rất đậm"
            }
        }
        var swiftUI: Font.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            }
        }
    }

    var resolvedGlobalAccent: Color {
        Color(hex: globalAccentHex) ?? AppTheme.accent
    }

    enum AppButtonStyle: String, CaseIterable, Identifiable {
        case original
        case futuristic
        case square

        var id: String { rawValue }
        var label: String {
            switch self {
            case .original: return "Kiểu gốc"
            case .futuristic: return "Công nghệ"
            case .square: return "Hình vuông"
            }
        }

        var icon: String {
            switch self {
            case .original: return "rectangle.roundedtop"
            case .futuristic: return "bolt.horizontal.circle"
            case .square: return "square"
            }
        }

        func cornerRadius(_ original: CGFloat) -> CGFloat {
            switch self {
            case .square: return 0
            case .futuristic: return min(max(original, 10), 18)
            case .original: return original
            }
        }
    }

    enum BorderStyle: String, CaseIterable, Identifiable {
        case transparent, colored
        var id: String { rawValue }
        var label: String { self == .transparent ? "Trong suốt" : "Màu tùy chỉnh" }
    }

    enum ColorSchemeMode: String, CaseIterable, Identifiable {
        case light, dark, system
        var id: String { rawValue }
        var label: String {
            switch self { case .light: return "Sáng"; case .dark: return "Tối"; case .system: return "Theo hệ thống" }
        }
        var swiftUIScheme: ColorScheme? {
            switch self { case .light: return .light; case .dark: return .dark; case .system: return nil }
        }
    }

    enum AppThemeMode: String, CaseIterable, Identifiable {
        case futuristic
        case `default`

        var id: String { rawValue }
        var label: String {
            switch self {
            case .futuristic: return "App công nghệ"
            case .default: return "App mặc định"
            }
        }
        var icon: String {
            switch self {
            case .futuristic: return "cpu.fill"
            case .default: return "sun.max.fill"
            }
        }
        var swiftUIScheme: ColorScheme {
            self == .futuristic ? .dark : .light
        }
    }

    // Background choices: existing light/dark plus separate static and animated anime wallpapers.
    enum BackgroundMode: String, CaseIterable, Identifiable {
        case light
        case dark
        case animeStatic
        case animeDynamic

        var id: String { rawValue }

        var label: String {
            switch self {
            case .light:        return "Light"
            case .dark:         return "Dark"
            case .animeStatic:  return "Anime Tĩnh"
            case .animeDynamic: return "Anime Động"
            }
        }

        var icon: String {
            switch self {
            case .light:        return "sun.max.fill"
            case .dark:         return "moon.stars.fill"
            case .animeStatic:  return "photo.fill"
            case .animeDynamic: return "play.rectangle.fill"
            }
        }

        static let animeStaticVideoURL =
            "https://www.image2url.com/r2/default/videos/1787889025768-ac5ecf62-46b4-4ef7-9e78-6811fb049295.mov"

        static let animeDynamicVideoURL =
            "https://www.image2url.com/r2/default/videos/1787889114375-161a0765-b87e-4203-95ea-0b9bc5476c84.mp4"

        static let lightSkyVideoURL =
            "https://www.image2url.com/r2/default/videos/1789268487742-fe0d586d-4bee-459a-8574-574ffabe4d2d.mp4"
    }

    private static func normalizedHex(_ value: String?, fallback: String) -> String {
        guard let value = value else { return fallback }
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !hex.hasPrefix("#") { hex = "#\(hex)" }
        let digits = "0123456789ABCDEF"
        guard hex.count == 7,
              hex.dropFirst().allSatisfy({ digits.contains($0) }) else {
            return fallback
        }
        return hex
    }

    var resolvedBorderColor: Color {
        Color(hex: borderColorHex) ?? Color(red: 0.18, green: 0.52, blue: 1.0)
    }

    var resolvedAppButtonColor: Color {
        Color(hex: appButtonColorHex) ?? Color(red: 0.18, green: 0.52, blue: 1.0)
    }

    var resolvedAppButtonBorderColor: Color {
        Color(hex: appButtonBorderColorHex) ?? resolvedAppButtonColor
    }
}


// MARK: - Dynamic wallpaper palette

/// Publishes a lightweight palette derived from the currently rendered video frame.
/// Sampling is throttled by the video engine and performed off the main thread.
final class DynamicWallpaperPalette: ObservableObject {
    static let shared = DynamicWallpaperPalette()

    @Published private(set) var accentColor: Color = AppTheme.accent
    @Published private(set) var foregroundColor: Color = .white
    @Published private(set) var secondaryColor: Color = .white.opacity(0.68)

    private var smoothedRGB: (r: CGFloat, g: CGFloat, b: CGFloat)?

    private init() {}

    /// A compact dynamic tint used by developer/status surfaces. The actual alpha
    /// is supplied by the shared opacity setting so every screen stays in sync.
    var adaptivePanelTint: Color {
        accentColor.opacity(0.34)
    }

    var adaptiveSurfaceTint: Color {
        foregroundColor.opacity(0.10)
    }

    func reset() {
        smoothedRGB = nil
        accentColor = AppTheme.accent
        foregroundColor = .white
        secondaryColor = .white.opacity(0.68)
    }

    func update(red: CGFloat, green: CGFloat, blue: CGFloat) {
        let clampedRed = min(max(red, 0), 1)
        let clampedGreen = min(max(green, 0), 1)
        let clampedBlue = min(max(blue, 0), 1)

        // Low-pass the sampled frame color so animated scenes do not cause
        // distracting one-frame color jumps in the developer UI.
        let previous = smoothedRGB ?? (clampedRed, clampedGreen, clampedBlue)
        let smoothing: CGFloat = 0.22
        let redValue = previous.r + (clampedRed - previous.r) * smoothing
        let greenValue = previous.g + (clampedGreen - previous.g) * smoothing
        let blueValue = previous.b + (clampedBlue - previous.b) * smoothing
        smoothedRGB = (redValue, greenValue, blueValue)

        let average = UIColor(
            red: redValue,
            green: greenValue,
            blue: blueValue,
            alpha: 1
        )

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)

        let boostedSaturation = min(max(saturation * 1.35, 0.42), 1.0)
        let boostedBrightness = min(max(brightness * 1.15, 0.68), 1.0)
        let accent = UIColor(
            hue: hue,
            saturation: boostedSaturation,
            brightness: boostedBrightness,
            alpha: 1
        )

        let luminance = (0.2126 * redValue) + (0.7152 * greenValue) + (0.0722 * blueValue)
        let foreground: UIColor = luminance > 0.56 ? .black : .white
        let secondary: UIColor = luminance > 0.56
            ? UIColor(white: 0.12, alpha: 0.72)
            : UIColor(white: 0.92, alpha: 0.72)

        accentColor = Color(uiColor: accent)
        foregroundColor = Color(uiColor: foreground)
        secondaryColor = Color(uiColor: secondary)
    }
}

fileprivate enum WallpaperStaticPaletteSampler {
    private static let worker = DispatchQueue(
        label: "com.threeoneosfive.wallpaper.static-palette",
        qos: .utility
    )

    static func sample(url: URL, palette: DynamicWallpaperPalette) {
        let process: (Data) -> Void = { data in
            worker.async {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(
                          source,
                          0,
                          [
                              kCGImageSourceCreateThumbnailFromImageAlways: true,
                              kCGImageSourceThumbnailMaxPixelSize: 64,
                              kCGImageSourceCreateThumbnailWithTransform: true
                          ] as CFDictionary
                      ),
                      let average = averageColor(from: image) else { return }

                DispatchQueue.main.async {
                    guard AppearanceSettings.shared.backgroundMode == .animeStatic else { return }
                    palette.update(red: average.r, green: average.g, blue: average.b)
                }
            }
        }

        if url.isFileURL {
            worker.async {
                guard let data = try? Data(contentsOf: url) else { return }
                process(data)
            }
        } else {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data else { return }
                process(data)
            }.resume()
        }
    }

    static func sample(image: CGImage, palette: DynamicWallpaperPalette) {
        worker.async {
            guard let average = averageColor(from: image) else { return }
            DispatchQueue.main.async {
                guard AppearanceSettings.shared.backgroundMode == .animeStatic else { return }
                palette.update(red: average.r, green: average.g, blue: average.b)
            }
        }
    }

    private static func averageColor(from image: CGImage) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let ciImage = CIImage(cgImage: image)
        let extent = ciImage.extent
        guard !extent.isEmpty, let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }

        let context = CIContext(options: [.cacheIntermediates: false])
        var pixels = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixels,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )

        return (
            CGFloat(pixels[0]) / 255,
            CGFloat(pixels[1]) / 255,
            CGFloat(pixels[2]) / 255
        )
    }
}

fileprivate final class WallpaperVideoPaletteSampler {
    private weak var player: AVQueuePlayer?
    private let palette: DynamicWallpaperPalette
    private let worker = DispatchQueue(label: "com.threeoneosfive.wallpaper.palette", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var timer: Timer?
    private var generation: UInt64 = 0
    private var currentItemID: ObjectIdentifier?
    private weak var outputItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?

    init(player: AVQueuePlayer, palette: DynamicWallpaperPalette) {
        self.player = player
        self.palette = palette
    }

    func start() {
        stopTimerOnly()
        generation &+= 1
        let activeGeneration = generation

        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.sample(generation: activeGeneration)
        }
        timer.tolerance = 0.04
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        sample(generation: activeGeneration)
    }

    func stop() {
        generation &+= 1
        stopTimerOnly()
        detachOutput()

        if Thread.isMainThread {
            palette.reset()
        } else {
            DispatchQueue.main.async { [palette] in
                palette.reset()
            }
        }
    }

    private func stopTimerOnly() {
        timer?.invalidate()
        timer = nil
    }

    private func detachOutput() {
        if let output = videoOutput, let item = outputItem {
            item.remove(output)
        }
        videoOutput = nil
        outputItem = nil
        currentItemID = nil
    }

    private func prepareOutput(for item: AVPlayerItem) {
        let id = ObjectIdentifier(item)
        guard currentItemID != id else { return }

        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        if let output = videoOutput {
            item.add(output)
            outputItem = item
        }
        currentItemID = id
    }

    private func sample(generation: UInt64) {
        guard let player, let item = player.currentItem else { return }
        prepareOutput(for: item)

        guard let output = videoOutput else { return }
        let hostTime = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: hostTime)

        guard itemTime.isValid,
              output.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = output.copyPixelBuffer(
                  forItemTime: itemTime,
                  itemTimeForDisplay: nil
              ) else {
            return
        }

        worker.async { [weak self, palette] in
            guard let self else { return }
            guard let average = self.averageColor(from: pixelBuffer) else { return }

            DispatchQueue.main.async { [weak self, palette] in
                guard let self, self.generation == generation else { return }
                palette.update(red: average.r, green: average.g, blue: average.b)
            }
        }
    }

    private func averageColor(from pixelBuffer: CVPixelBuffer) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard !extent.isEmpty else { return nil }

        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)

        guard let outputImage = filter.outputImage else { return nil }

        var pixels = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

        context.render(
            outputImage,
            toBitmap: &pixels,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        return (
            CGFloat(pixels[0]) / 255,
            CGFloat(pixels[1]) / 255,
            CGFloat(pixels[2]) / 255
        )
    }

    deinit {
        timer?.invalidate()
    }
}

// MARK: - Color hex helpers
extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let rgb = UInt64(h, radix: 16) else { return nil }
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >>  8) & 0xFF) / 255,
                  blue:  Double( rgb        & 0xFF) / 255)
    }
    var hexString: String {
        guard let comps = UIColor(self).cgColor.components, comps.count >= 3 else { return "#2F85FF" }
        return String(format: "#%02X%02X%02X",
                      Int(comps[0] * 255), Int(comps[1] * 255), Int(comps[2] * 255))
    }
}

// MARK: - REQ 3: StripedLightBackground
/// Brilliant bright-white textured striped pattern — high-end depth, not flat white
struct StripedLightBackground: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Base: soft pearl white
                Color(red: 0.96, green: 0.97, blue: 1.0)

                // Diagonal stripe layer 1 — ultra-bright white bands
                Canvas { ctx, size in
                    let stripe: CGFloat = 18
                    let gap:    CGFloat = 36
                    var x: CGFloat = -size.height
                    while x < size.width + size.height {
                        let path = Path { p in
                            p.move(to: CGPoint(x: x, y: 0))
                            p.addLine(to: CGPoint(x: x + stripe, y: 0))
                            p.addLine(to: CGPoint(x: x + stripe + size.height, y: size.height))
                            p.addLine(to: CGPoint(x: x + size.height, y: size.height))
                            p.closeSubpath()
                        }
                        ctx.fill(path, with: .color(Color.white.opacity(0.55)))
                        x += stripe + gap
                    }
                }

                // Stripe layer 2 — tighter, semi-transparent for depth
                Canvas { ctx, size in
                    let stripe: CGFloat = 6
                    let gap:    CGFloat = 18
                    var x: CGFloat = -size.height
                    while x < size.width + size.height {
                        let path = Path { p in
                            p.move(to: CGPoint(x: x, y: 0))
                            p.addLine(to: CGPoint(x: x + stripe, y: 0))
                            p.addLine(to: CGPoint(x: x + stripe + size.height, y: size.height))
                            p.addLine(to: CGPoint(x: x + size.height, y: size.height))
                            p.closeSubpath()
                        }
                        ctx.fill(path, with: .color(Color.white.opacity(0.30)))
                        x += stripe + gap
                    }
                }

                // Top-left radial highlight: brilliant center point
                RadialGradient(
                    colors: [Color.white.opacity(0.85), Color.clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: geo.size.width * 0.8
                )

                // Bottom-right cool-blue tint for premium depth
                RadialGradient(
                    colors: [Color(red: 0.82, green: 0.90, blue: 1.0).opacity(0.40), Color.clear],
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: geo.size.width * 0.7
                )
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Anime backgrounds
/// AVPlayerLooper-backed background. Playback is owned by the UIKit view so SwiftUI
/// state/layout updates do not pause or restart the animation.
struct AnimeVideoBackground: UIViewRepresentable {
    final class BGPlayerView: UIView {
        var player: AVQueuePlayer?
        var playerLooper: AVPlayerLooper?
        var playerLayer: AVPlayerLayer?
        fileprivate var paletteSampler: WallpaperVideoPaletteSampler?
        private let firstFrameView = UIImageView()
        private var readyObservation: NSKeyValueObservation?

        private var foregroundObserver: NSObjectProtocol?
        private var backgroundObserver: NSObjectProtocol?

        override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer?.frame = bounds
        }

        func startPlayback() {
            player?.play()
        }

        func installFirstFrame(_ image: UIImage?) {
            firstFrameView.image = image
            firstFrameView.contentMode = .scaleAspectFill
            firstFrameView.clipsToBounds = true
            firstFrameView.frame = bounds
            firstFrameView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if firstFrameView.superview == nil {
                insertSubview(firstFrameView, at: 0)
            }
        }

        func hideFirstFrameAfterVideoReady() {
            guard firstFrameView.image != nil, let playerLayer else { return }
            if playerLayer.isReadyForDisplay {
                fadeOutFirstFrame()
                return
            }

            readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                self?.fadeOutFirstFrame()
            }
        }

        private func fadeOutFirstFrame() {
            readyObservation?.invalidate()
            readyObservation = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.firstFrameView.image != nil else { return }
                UIView.animate(withDuration: 0.12, animations: {
                    self.firstFrameView.alpha = 0
                }, completion: { _ in
                    self.firstFrameView.image = nil
                })
            }
        }

        func stopPlayback() {
            player?.pause()
        }

        func installLifecycleObservers() {
            guard foregroundObserver == nil, backgroundObserver == nil else { return }
            let center = NotificationCenter.default

            foregroundObserver = center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.startPlayback()
                self?.paletteSampler?.start()
            }

            backgroundObserver = center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.stopPlayback()
                self?.paletteSampler?.stop()
            }
        }

        func tearDown() {
            readyObservation?.invalidate()
            readyObservation = nil
            firstFrameView.image = nil
            firstFrameView.removeFromSuperview()
            if let foregroundObserver {
                NotificationCenter.default.removeObserver(foregroundObserver)
                self.foregroundObserver = nil
            }
            if let backgroundObserver {
                NotificationCenter.default.removeObserver(backgroundObserver)
                self.backgroundObserver = nil
            }
            paletteSampler?.stop()
            player?.pause()
            playerLooper?.disableLooping()
            playerLayer?.player = nil
        }

        deinit {
            tearDown()
            player = nil
            playerLooper = nil
            playerLayer = nil
        }
    }

    let urlString: String
    let cacheKey: String

    init(urlString: String, cacheKey: String = "animeDynamic") {
        self.urlString = urlString
        self.cacheKey = cacheKey
    }

    func makeUIView(context: Context) -> BGPlayerView {
        let view = BGPlayerView()
        // Never paint an opaque black layer here. GlobalBackground remains the
        // visual fallback if the video cannot be decoded immediately.
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false

        if let firstFrameURL = AssetPreloadService.cachedFirstFrameURL(key: cacheKey),
           let firstFrame = UIImage(contentsOfFile: firstFrameURL.path) {
            view.installFirstFrame(firstFrame)
        }

        let sourceURL: URL
        if let cached = BackgroundAssetCache.cachedURL(for: cacheKey) {
            sourceURL = cached
        } else {
            guard let remote = URL(string: urlString) else { return view }
            sourceURL = remote
        }

        let item = AVPlayerItem(url: sourceURL)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .none

        let looper = AVPlayerLooper(player: player, templateItem: item)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        layer.needsDisplayOnBoundsChange = true

        let palette = DynamicWallpaperPalette.shared
        let sampler = WallpaperVideoPaletteSampler(player: player, palette: palette)

        view.player = player
        view.playerLooper = looper
        view.playerLayer = layer
        view.paletteSampler = sampler
        view.layer.insertSublayer(layer, at: 0)
        view.installLifecycleObservers()

        // Start exactly once. SwiftUI updateUIView only updates geometry.
        player.play()
        sampler.start()
        view.hideFirstFrameAfterVideoReady()
        return view
    }

    func updateUIView(_ uiView: BGPlayerView, context: Context) {
        uiView.playerLayer?.frame = uiView.bounds
        // Never pause, seek, or recreate the player here. SwiftUI state updates
        // must not interrupt AVPlayerLooper frame delivery.
    }

    static func dismantleUIView(_ uiView: BGPlayerView, coordinator: ()) {
        uiView.tearDown()
    }
}

struct AnimeStaticBackground: View {
    @State private var image: UIImage?
    @State private var isLoading = true

    private var cachedFirstFrame: UIImage? {
        guard let url = AssetPreloadService.cachedFirstFrameURL(key: "animeStatic") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    var body: some View {
        ZStack {
            // Use the cached first frame synchronously. The old implementation
            // painted black until AVAssetImageGenerator finished, which caused
            // the visible black flash during Patch navigation.
            Color.clear

            if let displayImage = image ?? cachedFirstFrame {
                Image(uiImage: displayImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .transition(.opacity)
            } else if isLoading {
                ProgressView()
                    .tint(.white.opacity(0.75))
            }
        }
        .ignoresSafeArea()
        .task(id: AppearanceSettings.shared.backgroundMode) {
            await loadFirstFrame()
        }
    }

    private func loadFirstFrame() async {
        isLoading = true

        let url = BackgroundAssetCache.cachedURL(for: "animeStatic")
            ?? URL(string: AppearanceSettings.BackgroundMode.animeStaticVideoURL)

        guard let url else {
            isLoading = false
            return
        }

        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)

        do {
            let result = try await generator.image(at: .zero)
            guard !Task.isCancelled else { return }
            let cgImage = result.image
            await MainActor.run {
                image = UIImage(cgImage: cgImage)
                isLoading = false
            }
            WallpaperStaticPaletteSampler.sample(
                image: cgImage,
                palette: DynamicWallpaperPalette.shared
            )
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run { isLoading = false }
        }
    }
}

// MARK: - Cosmic backgrounds
/// Shared high-tech cosmic field used by both light and dark themes.
/// The field is self-contained and has no network dependency.
struct CosmicBackground: View {
    let isDark: Bool

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    LinearGradient(
                        colors: isDark
                            ? [Color(red: 0.003, green: 0.006, blue: 0.014),
                               Color(red: 0.008, green: 0.022, blue: 0.055),
                               Color(red: 0.002, green: 0.008, blue: 0.020)]
                            : [Color(red: 0.96, green: 0.92, blue: 1.0),
                               Color(red: 0.82, green: 0.70, blue: 0.98),
                               Color(red: 0.93, green: 0.88, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()

                    RadialGradient(
                        colors: [
                            Color(red: 0.08, green: 0.52, blue: 1.0).opacity(isDark ? 0.34 : 0.24),
                            Color.clear
                        ],
                        center: UnitPoint(
                            x: 0.25 + 0.12 * sin(t * 0.22),
                            y: 0.20 + 0.10 * cos(t * 0.18)
                        ),
                        startRadius: 0,
                        endRadius: max(geo.size.width, geo.size.height) * 0.72
                    )
                    .ignoresSafeArea()

                    RadialGradient(
                        colors: [
                            Color(red: 0.04, green: 0.40, blue: 1.0).opacity(isDark ? 0.22 : 0.16),
                            Color.clear
                        ],
                        center: UnitPoint(
                            x: 0.82 + 0.10 * cos(t * 0.16),
                            y: 0.76 + 0.08 * sin(t * 0.20)
                        ),
                        startRadius: 0,
                        endRadius: max(geo.size.width, geo.size.height) * 0.62
                    )
                    .ignoresSafeArea()

                    Canvas { context, size in
                        let count = 90
                        for i in 0..<count {
                            let seed = Double(i * 7919 % 1000) / 1000.0
                            let seed2 = Double(i * 3571 % 1000) / 1000.0
                            let x = (seed + t * (0.004 + seed2 * 0.004)).truncatingRemainder(dividingBy: 1.0) * size.width
                            let y = seed2 * size.height
                            let pulse = 0.35 + 0.65 * abs(sin(t * (0.7 + seed) + seed2 * 8))
                            let radius: CGFloat = CGFloat(0.7 + seed * 1.5)
                            let rect = CGRect(x: x, y: y, width: radius, height: radius)
                            context.fill(
                                Path(ellipseIn: rect),
                                with: .color(.white.opacity((isDark ? 0.42 : 0.28) * pulse))
                            )
                        }
                    }
                    .ignoresSafeArea()

                    // Fine HUD grid, kept inside the visual field.
                    GridBackgroundView(
                        spacing: 32,
                        lineColor: Color(red: 0.08, green: 0.52, blue: 1.0).opacity(isDark ? 0.060 : 0.075)
                    )
                    .ignoresSafeArea()
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - TechStreakBackground
/// Pure-black dark-mode surface with animated diagonal white light beams.
/// Canvas keeps the rendering in one GPU-backed drawing pass instead of
/// creating a large SwiftUI view tree for every beam.
struct TechStreakBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 60.0,
                paused: reduceMotion || !appearance.animationsEnabled
            )
        ) { timeline in
            Canvas(opaque: true, colorMode: .linear) { context, size in
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(.black)
                )

                let time = reduceMotion
                    ? 0.0
                    : timeline.date.timeIntervalSinceReferenceDate
                let diagonal = max(size.width, size.height) * 1.45
                let beamCount = 9

                for index in 0..<beamCount {
                    let seed = Double(index) / Double(beamCount)
                    let phase = time * (0.34 + seed * 0.12) + seed * 9.0
                    let travel = (sin(phase) + 1.0) * 0.5
                    let x = -size.height * 0.28 + travel * (size.width + diagonal)
                    let y = size.height * (0.08 + seed * 0.92)

                    var beam = Path()
                    beam.move(to: CGPoint(
                        x: x - diagonal * 0.10,
                        y: y + diagonal * 0.035
                    ))
                    beam.addLine(to: CGPoint(
                        x: x + diagonal * 0.025,
                        y: y - diagonal * 0.015
                    ))
                    beam.addLine(to: CGPoint(
                        x: x + diagonal * 0.17,
                        y: y - diagonal * 0.035
                    ))
                    beam.addLine(to: CGPoint(
                        x: x + diagonal * 0.045,
                        y: y + diagonal * 0.015
                    ))
                    beam.closeSubpath()

                    let intensity = 0.10
                        + 0.16 * (0.5 + 0.5 * sin(phase * 1.7))
                    context.fill(
                        beam,
                        with: .color(.white.opacity(intensity))
                    )

                    var core = Path()
                    core.move(to: CGPoint(
                        x: x - diagonal * 0.02,
                        y: y + diagonal * 0.012
                    ))
                    core.addLine(to: CGPoint(
                        x: x + diagonal * 0.12,
                        y: y - diagonal * 0.028
                    ))
                    context.stroke(
                        core,
                        with: .color(.white.opacity(0.42 + intensity)),
                        style: StrokeStyle(
                            lineWidth: max(0.8, size.width * 0.0012),
                            lineCap: .round
                        )
                    )
                }

                // Counter-diagonal beams create the requested crossing/intersecting
                // white-light effect instead of a single-direction stripe field.
                for index in 0..<6 {
                    let seed = Double(index) / 6.0
                    let phase = time * (0.26 + seed * 0.10) + seed * 7.0 + 1.7
                    let travel = (sin(phase) + 1.0) * 0.5
                    let x = size.width * (0.02 + travel * 1.08)
                    let y = -size.width * 0.12 + size.height * (0.10 + seed * 0.92)
                    let span = diagonal * 0.20

                    var crossBeam = Path()
                    crossBeam.move(to: CGPoint(
                        x: x - span * 0.10,
                        y: y - span * 0.08
                    ))
                    crossBeam.addLine(to: CGPoint(
                        x: x + span * 0.03,
                        y: y + span * 0.015
                    ))
                    crossBeam.addLine(to: CGPoint(
                        x: x + span * 0.17,
                        y: y + span * 0.08
                    ))
                    crossBeam.addLine(to: CGPoint(
                        x: x + span * 0.04,
                        y: y - span * 0.015
                    ))
                    crossBeam.closeSubpath()

                    let intensity = 0.10 + 0.14 * (0.5 + 0.5 * sin(phase * 1.45))
                    context.fill(
                        crossBeam,
                        with: .color(.white.opacity(intensity))
                    )

                    var crossCore = Path()
                    crossCore.move(to: CGPoint(x: x - span * 0.02, y: y - span * 0.025))
                    crossCore.addLine(to: CGPoint(x: x + span * 0.13, y: y + span * 0.055))
                    context.stroke(
                        crossCore,
                        with: .color(.white.opacity(0.36 + intensity)),
                        style: StrokeStyle(
                            lineWidth: max(0.8, size.width * 0.0011),
                            lineCap: .round
                        )
                    )
                }

                // Small secondary streaks add depth without a particle system.
                for index in 0..<18 {
                    let seed = Double((index * 37) % 101) / 100.0
                    let phase = time * (0.12 + seed * 0.08) + seed * 12.0
                    let x = size.width * ((sin(phase) + 1.0) * 0.5)
                    let y = size.height * ((Double(index) + 0.5) / 18.0)

                    var micro = Path()
                    micro.move(to: CGPoint(x: x, y: y))
                    micro.addLine(to: CGPoint(
                        x: x + size.width * 0.10,
                        y: y - size.width * 0.035
                    ))
                    context.stroke(
                        micro,
                        with: .color(.white.opacity(0.08)),
                        style: StrokeStyle(lineWidth: 0.7, lineCap: .round)
                    )
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - GlobalBackground (REQ 3 — synced across all pages)
struct GlobalBackground: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @ObservedObject private var developerInfo = DeveloperInfoConfig.shared

    private var isLightMode: Bool {
        // The explicit background picker is the source of truth for the
        // visual surface. This prevents a legacy theme value from overriding
        // an explicitly selected Dark background.
        appearance.backgroundMode == .light
    }

    var body: some View {
        ZStack {
            if isLightMode {
                AnimeVideoBackground(
                    urlString: AppearanceSettings.BackgroundMode.lightSkyVideoURL,
                    cacheKey: "lightSky"
                )
                .ignoresSafeArea()
                .transition(.opacity)
            } else {
                switch appearance.backgroundMode {
                case .light:
                    AnimeVideoBackground(
                        urlString: AppearanceSettings.BackgroundMode.lightSkyVideoURL,
                        cacheKey: "lightSky"
                    )
                    .ignoresSafeArea()
                    .transition(.opacity)
                case .dark:
                    TechStreakBackground()
                case .animeStatic:
                    AnimeStaticBackground()
                        .transition(.opacity)
                case .animeDynamic:
                    AnimeVideoBackground(
                        urlString: AppearanceSettings.BackgroundMode.animeDynamicVideoURL,
                        cacheKey: "animeDynamic"
                    )
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
        }
        .overlay {
            if let avatarURL = developerInfo.avatarURL {
                AsyncImage(url: avatarURL, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .opacity(isLightMode ? 0.12 : 0.22)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .animation(.easeInOut(duration: 0.32), value: appearance.backgroundMode)
        .animation(.easeInOut(duration: 0.32), value: isLightMode)
    }
}

// MARK: - REQ 4: DevInfoPopup — "Thông tin DEV APP" bottom sheet
struct DevInfoPopup: View {
    @Binding var isPresented: Bool
    @ObservedObject private var appearance = AppearanceSettings.shared

    private var transparency: Double { min(max(appearance.dynamicOpacity, 0.05), 1.0) }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Transparent hit-test backdrop. No fixed black layer is introduced;
            // the Developer panel itself owns all blur/transparency visuals.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.interactiveSpring(response: 0.42, dampingFraction: 0.88, blendDuration: 0.16)) {
                        isPresented = false
                    }
                }

            DeveloperInfoContent {
                withAnimation(.interactiveSpring(response: 0.42, dampingFraction: 0.88, blendDuration: 0.16)) {
                    isPresented = false
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 66)
            .frame(maxWidth: 760)
            .padding(.top, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .ignoresSafeArea()
    }
}

// MARK: - KeyInfoCard
struct KeyInfoCard: View {
    let savedKey: String
    let keyDuration: String
    let keyExpiry: String
    let expiryTimestamp: Double
    let borderColor: Color
    let bgOpacity: Double
    let borderStyle: AppearanceSettings.BorderStyle

    @State private var keyVisible = false
    @State private var copied = false

    private var maskedKey: String {
        guard !savedKey.isEmpty else { return "Chưa có" }
        return String(repeating: "●", count: min(savedKey.count, 20))
    }

    var body: some View {
        VStack(spacing: 14) {
            // Key element: icon + key string are deliberately kept on one horizontal baseline.
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppTheme.accent.opacity(0.14))
                    Image(systemName: "key.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppTheme.accent)
                }
                .frame(width: 32, height: 32)

                ZStack(alignment: .leading) {
                    Text(savedKey.isEmpty ? "Chưa có" : (keyVisible ? savedKey : maskedKey))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    guard !savedKey.isEmpty else { return }
                    UIPasteboard.general.string = savedKey
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.70)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        withAnimation { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.clipboard.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(copied ? Color.green : AppTheme.accent)
                        .frame(width: 32, height: 32)
                        .background(AppTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain).techButtonChrome()
                .disabled(savedKey.isEmpty)

                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.68)) { keyVisible.toggle() }
                } label: {
                    Image(systemName: keyVisible ? "eye.fill" : "eye.slash.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(keyVisible ? AppTheme.accent : .secondary)
                        .frame(width: 32, height: 32)
                        .background(
                            (keyVisible ? AppTheme.accent : Color.primary).opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain).techButtonChrome()
                .disabled(savedKey.isEmpty)
            }
            .frame(minHeight: 32)

            // Protection notice sits directly below the key element.
            HStack(spacing: 7) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Key - Đang được bảo vệ")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
            }
            .foregroundStyle(AppTheme.accent.opacity(0.92))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(AppTheme.accent.opacity(min(max(bgOpacity, 0), 1) * 0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            HStack {
                Image(systemName: "clock.fill").foregroundStyle(.green).frame(width: 24)
                Text("Thời Gian").foregroundStyle(.secondary).fontWeight(.medium)
                Spacer()
                Text(keyDuration.isEmpty ? "Vĩnh viễn" : keyDuration).fontWeight(.bold)
            }

            HStack {
                Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(.red).frame(width: 24)
                Text("Hạn Sử Dụng").foregroundStyle(.secondary).fontWeight(.medium)
                Spacer()
                Text(keyExpiry.isEmpty ? "Không giới hạn" : keyExpiry).fontWeight(.bold)
            }

            LicenseCountdownView(expiryTimestamp: expiryTimestamp, lifetime: expiryTimestamp <= 0)

            Divider().opacity(0.16)

            Button {
                ["saved_key", "key_name", "key_duration", "key_expiry", "key_expiry_timestamp"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
                exit(0)
            } label: {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("Đăng Xuất Key").fontWeight(.bold)
                    Spacer()
                }
                .foregroundStyle(.red)
            }
            .buttonStyle(.plain).techButtonChrome()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground).opacity(min(max(bgOpacity, 0), 1)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - License countdown
private struct LicenseCountdownView: View {
    let expiryTimestamp: Double
    let lifetime: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, expiryTimestamp - context.date.timeIntervalSince1970)
            let totalMinutes = Int(remaining / 60)
            let days = totalMinutes / (24 * 60)
            let hours = (totalMinutes % (24 * 60)) / 60
            let minutes = totalMinutes % 60
            let expired = !lifetime && remaining <= 0

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: expired ? "exclamationmark.triangle.fill" : "timer")
                        .font(.system(size: 12, weight: .bold))
                    Text(lifetime ? "THỜI HẠN: VĨNH VIỄN" : (expired ? "KEY ĐÃ HẾT HẠN" : "THỜI GIAN CÒN LẠI"))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(0.7)
                    Spacer()
                }
                .foregroundStyle(expired ? .red : AppTheme.accent)

                HStack(spacing: 8) {
                    countdownUnit(value: days, label: "NGÀY")
                    countdownUnit(value: hours, label: "GIỜ")
                    countdownUnit(value: minutes, label: "PHÚT")
                }
            }
            .padding(12)
            .background(AppTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.clear, lineWidth: 0)
            }
            .shadow(color: (expired ? Color.red : AppTheme.accent).opacity(0.18), radius: 10)
        }
    }

    private func countdownUnit(value: Int, label: String) -> some View {
        VStack(spacing: 3) {
            Text(String(format: "%02d", value))
                .font(.system(size: 19, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - SettingsView
struct SettingsView: View {
    @Environment(\.dismiss)      private var dismiss
    let showsDoneButton: Bool

    init(showsDoneButton: Bool = true) { self.showsDoneButton = showsDoneButton }

    @Environment(\.appLanguage)  private var language
    @ObservedObject private var appearance   = AppearanceSettings.shared
    @ObservedObject private var audioPlayer  = ZHModzAudioPlayer.shared

    // REQ 4: Dev info popup
    @State private var showDevInfo             = false


    var body: some View {
        NavigationStack {
            ZStack {
                GlobalBackground()

                Form {
                    Section("Thông tin DEV APP") {
                        DeveloperInfoCard {
                            withAnimation(appearance.animationsEnabled ? .spring(response: 0.38 * appearance.animationDurationMultiplier, dampingFraction: 0.80) : nil) {
                                showDevInfo = true
                            }
                        }
                    }
                    .listRowBackground(rowBG)

                    Section("Nhạc") {
                        HStack(spacing: 12) {
                            Image(systemName: audioPlayer.isPlaying ? "music.note" : "music.note.slash")
                                .foregroundStyle(audioPlayer.isPlaying ? Color.green : Color.secondary)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Nhạc nền").foregroundStyle(.primary)
                                Text(audioPlayer.isPlaying ? "Đang bật" : "Đang tắt")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Nhạc nền", isOn: Binding(
                                get: { audioPlayer.isPlaying },
                                set: { enabled in enabled ? audioPlayer.play() : audioPlayer.stop() }
                            ))
                            .labelsHidden()
                            .tint(AppTheme.accent)
                        }
                        .padding(.vertical, 5)
                    }
                    .listRowBackground(rowBG)

                }
                .scrollContentBackground(.hidden)

                // REQ 4: DevInfoPopup overlay
                if showDevInfo {
                    DevInfoPopup(isPresented: $showDevInfo)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal:   .move(edge: .bottom).combined(with: .opacity)
                        ))
                        .zIndex(500)
                }
            }
            .tint(AppTheme.accent)
            .navigationTitle(language.text("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(language.text("common.done")) { dismiss() }.fontWeight(.semibold)
                    }
                }
            }
            .preferredColorScheme(appearance.appThemeMode.swiftUIScheme)
            .onChange(of: audioPlayer.isPlaying) { value in
                FluxStatusNotificationCenter.shared.post(
                    title: "Background audio",
                    detail: value ? "Music playback enabled" : "Music playback disabled",
                    isOn: value
                )
            }
            .animation(appearance.animationsEnabled ? .spring(response: 0.38 * appearance.animationDurationMultiplier, dampingFraction: 0.80) : nil, value: showDevInfo)
        }
    }

    private func patchFunctionAppearanceRow(
        icon: String,
        title: String,
        color: Binding<Color>,
        opacity: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(color.wrappedValue)
                    .frame(width: 24)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                ColorPicker(
                    "",
                    selection: color,
                    supportsOpacity: false
                )
                .labelsHidden()

                Text(String(format: "%.0f%%", opacity.wrappedValue * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }

            Slider(value: opacity, in: 0.10...1.0, step: 0.01)
                .tint(color.wrappedValue)
                .accessibilityLabel("Độ trong \(title)")
        }
        .padding(.vertical, 4)
    }

    // MARK: Helpers
    private var rowBG: some View {
        appearance.appThemeMode == .futuristic
            ? Color.black.opacity(0.42)
            : Color.white.opacity(0.82)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "AppReleaseDisplayVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
    }

    @ViewBuilder
    private func settingsRow(icon: String, color: Color, text: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundColor(color).frame(width: 24)
            Text(text).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func settingsSliderRow(
        icon: String,
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(.cyan)
                    .frame(width: 24)
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.gray)
            }
            Slider(value: value, in: range, step: range.upperBound > 5 ? 1 : 0.01)
                .tint(.cyan)
        }
        .padding(.vertical, 4)
    }

    private func versionLabel(_ v: (beta: Int, publicBeta: Int?, build: String)) -> String {
        if let pb = v.publicBeta {
            return language.text("settings.developer_public_beta_build", Int64(v.beta), Int64(pb), v.build)
        }
        return language.text("settings.developer_beta_build", Int64(v.beta), v.build)
    }

    private func clearTempPatchCache() {
        let tmp = FileManager.default.temporaryDirectory
        let items = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.pathExtension == "3105" { try? FileManager.default.removeItem(at: item) }
        log("settings: cleared .3105 temp cache")
    }
}


