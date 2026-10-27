import Foundation
import SwiftUI

/// Runtime configuration supplied by the Web Admin for the Patch screen.
struct PatchRuntimeConfig: Equatable {
    let menuName: String
    let categoryNames: [String: String]
    let dnsButtonText: String
    let dnsLink: String
    let videoButtonText: String
    let videoLink: String

    static let `default` = PatchRuntimeConfig(
        menuName: "Patch",
        categoryNames: ["MOD": "MOD", "HOLO": "HOLO", "AIM": "AIM", "MENU": "MENU"],
        dnsButtonText: "DNS",
        dnsLink: "",
        videoButtonText: "Video",
        videoLink: ""
    )

    func categoryName(for raw: String) -> String {
        categoryNames[raw.uppercased()] ?? raw
    }
}

@MainActor
final class RuntimeContentService: ObservableObject {
    static let shared = RuntimeContentService()

    @Published private(set) var patchRuntimeConfig: PatchRuntimeConfig = .default
    @Published private(set) var isLoadingPatchRuntime = false

    private init() {}

    /// Reads the same public bootstrap endpoint used by the App boot flow.
    /// No patch/package resource is requested here.
    func refreshPatchRuntimeConfig() async {
        guard !isLoadingPatchRuntime else { return }
        isLoadingPatchRuntime = true
        defer { isLoadingPatchRuntime = false }

        guard let url = URL(string: "https://appfluxcore.site/api/app_bootstrap.php?app=fluxcore") else { return }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }

            let payload = try JSONDecoder().decode(BootstrapPayload.self, from: data)
            let menu = payload.menuName.trimmingCharacters(in: .whitespacesAndNewlines)
            patchRuntimeConfig = PatchRuntimeConfig(
                menuName: menu.isEmpty ? "Patch" : String(menu.prefix(80)),
                categoryNames: [
                    "MOD": String(payload.modName.prefix(80)),
                    "HOLO": String(payload.holoName.prefix(80)),
                    "AIM": String(payload.aimName.prefix(80)),
                    "MENU": String(payload.menuCategoryName.prefix(80))
                ],
                dnsButtonText: sanitizedLabel(payload.dnsButtonText, fallback: "DNS"),
                dnsLink: validHTTPURL(payload.dnsLink) ?? "",
                videoButtonText: sanitizedLabel(payload.videoButtonText, fallback: "Video"),
                videoLink: validHTTPURL(payload.videoLink) ?? ""
            )
        } catch {
            log("patch-runtime: config fetch failed – \(error.localizedDescription)")
        }
    }

    private func sanitizedLabel(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(80))
    }

    private func validHTTPURL(_ value: String) -> String? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !url.host.isNilOrEmpty else { return nil }
        return url.absoluteString
    }

    private struct BootstrapPayload: Decodable {
        let menuName: String
        let aimName: String
        let holoName: String
        let modName: String
        let menuCategoryName: String
        let dnsButtonText: String
        let dnsLink: String
        let videoButtonText: String
        let videoLink: String

        enum CodingKeys: String, CodingKey {
            case menuName = "menu_name"
            case dnsButtonText = "dns_button_text"
            case dnsLink = "dns_link"
            case videoButtonText = "video_button_text"
            case videoLink = "video_link"
            case patchUI = "patch_ui"
        }

        private struct PatchUI: Decodable {
            let menuName: String
            let categories: [String: String]

            enum CodingKeys: String, CodingKey {
                case menuName = "menu_name"
                case categories
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let ui = try c.decodeIfPresent(PatchUI.self, forKey: .patchUI)
            menuName = ui?.menuName ?? "Patch"
            aimName = ui?.categories["AIM"] ?? "AIM"
            holoName = ui?.categories["HOLO"] ?? "HOLO"
            modName = ui?.categories["MOD"] ?? "MOD"
            menuCategoryName = ui?.categories["MENU"] ?? "MENU"
            dnsButtonText = try c.decodeIfPresent(String.self, forKey: .dnsButtonText) ?? "DNS"
            dnsLink = try c.decodeIfPresent(String.self, forKey: .dnsLink) ?? ""
            videoButtonText = try c.decodeIfPresent(String.self, forKey: .videoButtonText) ?? "Video"
            videoLink = try c.decodeIfPresent(String.self, forKey: .videoLink) ?? ""
        }
    }
}

struct RemoteUpdateModal: View {
    let offer: AppUpdateChecker.Offer
    let onOpen: () -> Void
    var onDismiss: () -> Void = {}

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Label(offer.isMandatory ? "BẢN CẬP NHẬT BẮT BUỘC" : "CÓ BẢN CẬP NHẬT MỚI", systemImage: "arrow.down.app.fill")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.accent)
                    Spacer()
                }
                .padding(20)

                Divider().overlay(.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Phiên bản \(offer.version)")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(.white)

                    Text(offer.message.isEmpty ? "Vui lòng cập nhật ứng dụng để tiếp tục." : offer.message)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)

                Button(action: onOpen) {
                    Label("CẬP NHẬT NGAY", systemImage: "arrow.up.right")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                if !offer.isMandatory { Button("Để sau", action: onDismiss).padding(.bottom, 20) }
            }
            .frame(maxWidth: 560)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 35, y: 18)
            .padding(20)
        }
        .allowsHitTesting(true)
        .zIndex(20_000)
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        guard let self else { return true }
        return self.isEmpty
    }
}
