import Foundation
import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

// MARK: - Chat API Models

struct FluxChatProfile: Codable, Identifiable, Equatable {
    let id: Int
    let key: String
    var display_name: String
    var icon: String
    var avatar_url: String
    var is_admin: Bool
    var admin_label: String
    var admin_color: String
    var online: Bool
    var expires_at: String?
    var lifetime: Bool
    var notifications_enabled: Bool
    var has_password: Bool
    var recovery_email: Bool
    var recovery_telegram: Bool
}

struct FluxChatGroup: Codable, Identifiable, Equatable {
    let id: Int
    let slug: String
    let name: String
    let description: String
    let announcement_only: Bool
}

struct FluxChatFriend: Codable, Identifiable, Equatable {
    let id: Int
    let friendship_id: Int
    let status: String
    let key: String
    let display_name: String
    let icon: String
    let avatar_url: String
    let is_admin: Bool
    let admin_label: String
    let admin_color: String
    let online: Bool
    let expires_at: String?
    let lifetime: Bool
    let notifications_enabled: Bool
    let has_password: Bool
    let recovery_email: Bool
    let recovery_telegram: Bool
    var notifications_enabled_for_me: Bool = true
}

struct FluxChatConversation: Codable, Identifiable, Equatable {
    let id: Int
    let type: String
    let title: String
    let created_by: Int
    let created_at: String
}

struct FluxChatAttachment: Codable, Equatable {
    let name: String
    let mime: String
    let size: Int
    let url: String
}

struct FluxChatMessage: Codable, Identifiable, Equatable {
    let id: Int
    let conversation_id: String
    let sender: FluxChatProfile
    var body: String
    let message_type: String
    let attachment: FluxChatAttachment?
    var is_pinned: Bool
    var edited: Bool
    let created_at: String
    let updated_at: String
}

private struct PasswordStatusResponse: Codable {
    let success: Bool
    let has_password: Bool
    let profile: FluxChatProfile?
}

private struct ChatLoginResponse: Codable {
    let success: Bool
    let token: String?
    let profile: FluxChatProfile?
    let message: String?
}

private struct ChatBootstrapResponse: Codable {
    let success: Bool
    let profile: FluxChatProfile
    let groups: [FluxChatGroup]
    let friends: [FluxChatFriend]
    let private_conversations: [FluxChatConversation]
}

private struct ChatMessagesResponse: Codable {
    let success: Bool
    let messages: [FluxChatMessage]
}

private struct ChatMessageResponse: Codable {
    let success: Bool
    let message: FluxChatMessage
}

private struct ChatProfileResponse: Codable {
    let success: Bool
    let profile: FluxChatProfile
}

private struct ChatGenericResponse: Codable {
    let success: Bool
    let message: String?
    let conversation: FluxChatConversation?
}

@MainActor
final class FluxChatService: ObservableObject {
    static let shared = FluxChatService()

    private let endpoint = URL(string: "https://appfluxcore.site/api/chat.php")!
    private let session: URLSession
    private let defaults = UserDefaults.standard

    @Published private(set) var token: String = ""
    @Published private(set) var profile: FluxChatProfile?
    @Published private(set) var groups: [FluxChatGroup] = []
    @Published private(set) var friends: [FluxChatFriend] = []
    @Published private(set) var messages: [FluxChatMessage] = []
    @Published private(set) var activeConversation = "general"
    @Published private(set) var activeTitle = "Nhóm chung"
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var streamTask: Task<Void, Never>?
    private var lastMessageID = 0
    private var oldestMessageID = 0
    @Published private(set) var hasOlderMessages = false
    @Published private(set) var passwordGateRequired = false
    @Published private(set) var passwordGateUnlocked = false

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 35
        session = URLSession(configuration: configuration)
        token = defaults.string(forKey: "flux.chat.token") ?? ""
    }

    var isAuthenticated: Bool { !token.isEmpty && profile != nil }
    var savedKey: String { defaults.string(forKey: "saved_key") ?? "" }

    func prepareForAppLaunch(key: String) async {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return }
        do {
            let status: PasswordStatusResponse = try await requestPublic(
                action: "password_status", query: ["key": normalized]
            )
            passwordGateRequired = status.has_password
            passwordGateUnlocked = !status.has_password
            if status.has_password {
                // A password-protected Key must always pass the gate on each app launch.
                logout()
            } else if !token.isEmpty {
                await autoLogin()
            } else {
                await login(key: normalized, password: "")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unlockApp(key: String, password: String) async -> Bool {
        await login(key: key, password: password)
        let ok = isAuthenticated
        if ok {
            passwordGateUnlocked = true
            passwordGateRequired = false
        }
        return ok
    }

    func login(key: String, password: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response: ChatLoginResponse = try await request(
                action: "login",
                method: "POST",
                body: ["key": key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                       "password": password]
            )
            guard response.success, let token = response.token, let profile = response.profile else {
                throw ChatAPIError.server(response.message ?? "Đăng nhập Chat thất bại")
            }

            self.token = token
            self.profile = profile
            defaults.set(token, forKey: "flux.chat.token")
            await bootstrap()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func autoLogin() async {
        guard !token.isEmpty else { return }
        await bootstrap()
    }

    func bootstrap() async {
        do {
            let response: ChatBootstrapResponse = try await request(
                action: "bootstrap",
                method: "GET"
            )
            profile = response.profile
            groups = response.groups
            friends = response.friends
            startRealtimeStream()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectRoom(id: String, title: String) {
        activeConversation = id
        activeTitle = title
        messages = []
        lastMessageID = 0
        oldestMessageID = 0
        hasOlderMessages = false
        streamTask?.cancel()
        Task { await loadMessages(initial: true); startRealtimeStream() }
    }

    func openPrivateChat(with key: String) async {
        do {
            let response: ChatGenericResponse = try await request(
                action: "conversation",
                method: "POST",
                body: ["key": key]
            )
            guard let conversation = response.conversation else { return }
            selectRoom(id: String(conversation.id), title: key)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMessages(initial: Bool = false) async {
        guard !token.isEmpty else { return }
        do {
            var query = ["conversation_id": activeConversation, "limit": "50"]
            if initial {
                query["before"] = "0"
            } else {
                query["after"] = String(lastMessageID)
            }
            let response: ChatMessagesResponse = try await request(action: "messages", method: "GET", query: query)
            if initial {
                messages = response.messages
                oldestMessageID = messages.first?.id ?? 0
                lastMessageID = messages.last?.id ?? 0
                hasOlderMessages = messages.count >= 50
            } else {
                appendMessages(response.messages)
            }
        } catch {
            if case ChatAPIError.unauthorized = error { logout() }
        }
    }

    func loadOlderMessages() async {
        guard !token.isEmpty, oldestMessageID > 0, hasOlderMessages else { return }
        do {
            let response: ChatMessagesResponse = try await request(
                action: "messages", method: "GET",
                query: ["conversation_id": activeConversation, "before": String(oldestMessageID), "limit": "50"]
            )
            let incoming = response.messages.filter { m in !messages.contains(where: { $0.id == m.id }) }
            messages.insert(contentsOf: incoming, at: 0)
            oldestMessageID = messages.first?.id ?? oldestMessageID
            hasOlderMessages = incoming.count >= 50
        } catch {
            if case ChatAPIError.unauthorized = error { logout() }
        }
    }

    private func appendMessages(_ incoming: [FluxChatMessage]) {
        for message in incoming where !messages.contains(where: { $0.id == message.id }) {
            messages.append(message)
        }
        messages.sort { $0.id < $1.id }
        lastMessageID = messages.last?.id ?? lastMessageID
        oldestMessageID = messages.first?.id ?? oldestMessageID
    }

    func send(text: String) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        do {
            let response: ChatMessageResponse = try await request(
                action: "send",
                method: "POST",
                body: ["conversation_id": activeConversation, "body": body]
            )
            appendMessages([response.message])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func upload(fileURL: URL, body: String) async {
        guard !token.isEmpty else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= 25 * 1024 * 1024 else {
                throw ChatAPIError.server("File tối đa 25 MB")
            }

            let boundary = "FluxChat-\(UUID().uuidString)"
            var request = URLRequest(url: endpoint.appending(queryItems: [
                URLQueryItem(name: "action", value: "upload")
            ]))
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            let filename = fileURL.lastPathComponent
            let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            var multipart = Data()

            func append(_ value: String) {
                multipart.append(value.data(using: .utf8)!)
            }

            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"conversation_id\"\r\n\r\n")
            append(activeConversation)
            append("\r\n")
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"body\"\r\n\r\n")
            append(body)
            append("\r\n")
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename.replacingOccurrences(of: "\"", with: "_"))\"\r\n")
            append("Content-Type: \(mime)\r\n\r\n")
            multipart.append(data)
            append("\r\n--\(boundary)--\r\n")

            let (responseData, response) = try await session.upload(for: request, from: multipart)
            guard let http = response as? HTTPURLResponse else { throw ChatAPIError.invalidResponse }
            let decoded = try JSONDecoder().decode(ChatMessageResponse.self, from: responseData)
            guard (200..<300).contains(http.statusCode), decoded.success else {
                throw ChatAPIError.server("Upload thất bại")
            }
            messages.append(decoded.message)
            lastMessageID = max(lastMessageID, decoded.message.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func uploadAvatar(data: Data, mime: String = "image/jpeg", filename: String = "avatar.jpg") async {
        guard !token.isEmpty else { return }
        guard data.count <= 8 * 1024 * 1024 else {
            errorMessage = "Ảnh avatar tối đa 8MB"
            return
        }
        guard ["image/jpeg", "image/png", "image/webp", "image/gif"].contains(mime) else {
            errorMessage = "Chỉ hỗ trợ JPG, PNG, WEBP hoặc GIF"
            return
        }

        do {
            let boundary = "FluxAvatar-\(UUID().uuidString)"
            var request = URLRequest(url: endpoint.appending(queryItems: [
                URLQueryItem(name: "action", value: "profile_avatar")
            ]))
            request.httpMethod = "POST"
            request.timeoutInterval = 45
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            var multipart = Data()
            func append(_ value: String) {
                multipart.append(value.data(using: .utf8)!)
            }

            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename.replacingOccurrences(of: "\"", with: "_"))\"\r\n")
            append("Content-Type: \(mime)\r\n\r\n")
            multipart.append(data)
            append("\r\n--\(boundary)--\r\n")

            let (responseData, response) = try await session.upload(for: request, from: multipart)
            guard let http = response as? HTTPURLResponse else {
                throw ChatAPIError.invalidResponse
            }
            let decoded = try JSONDecoder().decode(ChatProfileResponse.self, from: responseData)
            guard (200..<300).contains(http.statusCode), decoded.success else {
                throw ChatAPIError.server("Upload avatar thất bại")
            }
            profile = decoded.profile
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addFriend(key: String) async {
        do {
            let _: ChatGenericResponse = try await request(
                action: "friend_add",
                method: "POST",
                body: ["key": key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()]
            )
            await bootstrap()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func respond(friendshipID: Int, accept: Bool) async {
        do {
            let _: ChatGenericResponse = try await request(
                action: "friend_respond",
                method: "POST",
                body: ["friendship_id": friendshipID, "accept": accept]
            )
            await bootstrap()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateProfile(displayName: String, icon: String, avatarURL: String,
                       password: String, email: String, telegram: String) async {
        do {
            let response: ChatProfileResponse = try await request(
                action: "profile",
                method: "POST",
                body: [
                    "display_name": displayName,
                    "icon": icon,
                    "avatar_url": avatarURL,
                    "password": password,
                    "recovery_email": email,
                    "recovery_telegram": telegram
                ]
            )
            profile = response.profile
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setNotifications(enabled: Bool, scope: String = "all", target: String = "") async {
        do {
            let _: ChatGenericResponse = try await request(
                action: "notifications",
                method: "POST",
                body: ["enabled": enabled, "scope": scope, "target": target]
            )
            if scope == "all", var p = profile {
                p.notifications_enabled = enabled
                profile = p
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestRecovery(key: String, channel: String) async -> String? {
        do {
            let response: ChatGenericResponse = try await request(
                action: "recovery_request",
                method: "POST",
                body: ["key": key, "channel": channel]
            )
            return response.message
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func resetRecovery(key: String, code: String, password: String) async -> String? {
        do {
            let response: ChatGenericResponse = try await request(
                action: "recovery_reset",
                method: "POST",
                body: ["key": key, "code": code, "password": password]
            )
            return response.message
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func logout() {
        streamTask?.cancel()
        streamTask = nil
        token = ""
        profile = nil
        messages = []
        groups = []
        friends = []
        lastMessageID = 0
        defaults.removeObject(forKey: "flux.chat.token")
    }

    private func startRealtimeStream() {
        streamTask?.cancel()
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && !self.token.isEmpty {
                do {
                    try await self.consumeSSE()
                } catch is CancellationError {
                    return
                } catch ChatAPIError.unauthorized {
                    self.logout()
                    return
                } catch {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func consumeSSE() async throws {
        var components = URLComponents(url: URL(string: "https://appfluxcore.site/api/chat_stream.php")!, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "conversation_id", value: activeConversation),
            URLQueryItem(name: "after", value: String(lastMessageID))
        ]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.timeoutInterval = 35
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw ChatAPIError.invalidResponse }
        if http.statusCode == 401 { throw ChatAPIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw ChatAPIError.server("Realtime HTTP \(http.statusCode)") }

        var event = ""
        var dataLines: [String] = []
        for try await line in bytes.lines {
            if line.hasPrefix("event:") { event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("data:") { dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
            else if line.isEmpty {
                guard event == "message", !dataLines.isEmpty else { event = ""; dataLines.removeAll(); continue }
                let payload = dataLines.joined(separator: "\n")
                if let data = payload.data(using: .utf8), let message = try? JSONDecoder().decode(FluxChatMessage.self, from: data) {
                    appendMessages([message])
                }
                event = ""
                dataLines.removeAll()
            }
        }
    }

    private func requestPublic<T: Decodable>(action: String, query: [String: String]) async throws -> T {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "action", value: action)] + query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ChatAPIError.invalidResponse }
        let decoder = JSONDecoder()
        if !(200..<300).contains(http.statusCode) {
            let error = try? decoder.decode(ChatGenericResponse.self, from: data)
            throw ChatAPIError.server(error?.message ?? "API trả về HTTP \(http.statusCode)")
        }
        return try decoder.decode(T.self, from: data)
    }

    private func request<T: Decodable>(
        action: String,
        method: String,
        body: [String: Any] = [:],
        query: [String: String] = [:]
    ) async throws -> T {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var queryItems = [URLQueryItem(name: "action", value: action)]
        queryItems.append(contentsOf: query.map { URLQueryItem(name: $0.key, value: $0.value) })
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 25

        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatAPIError.invalidResponse }
        if http.statusCode == 401 { throw ChatAPIError.unauthorized }
        let decoder = JSONDecoder()
        if !(200..<300).contains(http.statusCode) {
            let error = try? decoder.decode(ChatGenericResponse.self, from: data)
            throw ChatAPIError.server(error?.message ?? "API trả về HTTP \(http.statusCode)")
        }
        return try decoder.decode(T.self, from: data)
    }
}

enum ChatAPIError: LocalizedError {
    case unauthorized
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Phiên Chat đã hết hạn."
        case .invalidResponse: return "Phản hồi máy chủ không hợp lệ."
        case .server(let message): return message
        }
    }
}

// MARK: - Chat Root

struct FluxChatView: View {
    @StateObject private var service = FluxChatService.shared
    @State private var loginKey = ""
    @State private var loginPassword = ""
    @State private var composer = ""
    @State private var selectedFile: URL?
    @State private var showingFileImporter = false
    @State private var friendKey = ""
    @State private var showAddFriend = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if service.isAuthenticated {
                chatBody
            } else {
                chatLogin
            }
        }
        .task {
            if !service.isAuthenticated {
                await service.autoLogin()
                if !service.isAuthenticated, !service.savedKey.isEmpty {
                    await service.login(key: service.savedKey, password: "")
                }
            }
        }
        .alert("Chat", isPresented: Binding(
            get: { service.errorMessage != nil },
            set: { if !$0 { service.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(service.errorMessage ?? "")
        }
    }

    private var chatLogin: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(AppTheme.accent)
                Text("Chat")
                    .font(.system(size: 30, weight: .bold))
                Text("Đăng nhập bằng Key tài khoản")
                    .foregroundStyle(.secondary)
                TextField("KEY", text: $loginKey)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                SecureField("Mật khẩu Key (nếu có)", text: $loginPassword)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await service.login(key: loginKey, password: loginPassword) }
                } label: {
                    HStack {
                        if service.isLoading { ProgressView().tint(.white) }
                        Text("Đăng nhập Chat")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(loginKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.isLoading)
            }
            .padding(24)
        }
    }

    private var chatBody: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            conversation
        }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: [.image, .movie, .pdf, .plainText, .zip, .data]) { result in
            if case .success(let url) = result {
                selectedFile = url
                Task {
                    await service.upload(fileURL: url, body: composer)
                    composer = ""
                }
            }
        }
        .sheet(isPresented: $showAddFriend) {
            NavigationStack {
                Form {
                    Section("Thêm bạn") {
                        TextField("Key người bạn", text: $friendKey)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Text("Sau khi gửi lời mời, người nhận phải chấp nhận trước khi hai tài khoản có thể nhắn tin riêng.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Button("Gửi lời mời kết bạn") {
                            let key = friendKey
                            friendKey = ""
                            showAddFriend = false
                            Task { await service.addFriend(key: key) }
                        }
                        .disabled(friendKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .navigationTitle("Thêm bạn")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Đóng") { showAddFriend = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chat")
                .font(.title2.bold())
            if let p = service.profile {
                HStack {
                    avatar(p, size: 38)
                    VStack(alignment: .leading) {
                        Text(p.display_name).font(.headline)
                        Text(p.is_admin ? "Admin" : p.key).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nhóm").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(service.groups) { group in
                        roomButton(
                            id: group.slug,
                            title: group.name,
                            icon: group.announcement_only ? "megaphone.fill" : "person.3.fill"
                        )
                    }

                    HStack {
                        Text("Bạn bè").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            showAddFriend = true
                        } label: {
                            Image(systemName: "person.badge.plus")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 10)

                    ForEach(service.friends) { friend in
                        if friend.status == "accepted" {
                            Button {
                                Task { await service.openPrivateChat(with: friend.key) }
                            } label: {
                                HStack {
                                    avatar(friend, size: 30)
                                    Text(friend.display_name).lineLimit(1)
                                    if friend.online {
                                        Circle().fill(.green).frame(width: 7, height: 7)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                        } else if friend.status == "pending" {
                            HStack {
                                Text(friend.display_name).font(.caption)
                                Spacer()
                                Button("✓") { Task { await service.respond(friendshipID: friend.friendship_id, accept: true) } }
                                Button("×") { Task { await service.respond(friendshipID: friend.friendship_id, accept: false) } }
                            }
                        }
                    }
                }
            }

            NavigationLink {
                FluxChatView()
            } label: {
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
            }
            .buttonStyle(.bordered)

            NavigationLink {
                FluxAccountView(service: service)
            } label: {
                Label("Tài Khoản", systemImage: "person.crop.circle")
            }
            .buttonStyle(.bordered)

            Button("Đăng xuất") { service.logout() }
                .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(minWidth: 210, maxWidth: 260)
    }

    private func roomButton(id: String, title: String, icon: String) -> some View {
        Button {
            service.selectRoom(id: id, title: title)
        } label: {
            HStack {
                Image(systemName: icon)
                Text(title)
                Spacer()
                if id == "announcements" { Image(systemName: "lock.fill").font(.caption) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(service.activeConversation == id ? AppTheme.accent.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(service.activeTitle).font(.headline)
                    Text(service.activeConversation == "announcements" ? "Chỉ Admin được gửi" : "Trực tuyến")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            ScrollViewReader { proxy in
                VStack(spacing: 6) {
                    if service.hasOlderMessages {
                        Button("Tải tin nhắn cũ hơn") { Task { await service.loadOlderMessages() } }
                            .buttonStyle(.bordered)
                            .font(.caption)
                    }
                    ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(service.messages) { message in
                            FluxMessageRow(message: message, currentProfileID: service.profile?.id)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                    .onChange(of: service.messages.count) { _ in
                        if let id = service.messages.last?.id {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button { showingFileImporter = true } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.bordered)

                TextField("Tin nhắn...", text: $composer, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .textFieldStyle(.roundedBorder)

                Button {
                    let text = composer
                    composer = ""
                    Task { await service.send(text: text) }
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func avatar(_ p: FluxChatProfile, size: CGFloat) -> some View {
        Group {
            if let url = URL(string: p.avatar_url), !p.avatar_url.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: Image(systemName: p.icon).resizable().scaledToFit().padding(size * 0.25)
                    }
                }
            } else {
                Image(systemName: p.icon).resizable().scaledToFit().padding(size * 0.25)
            }
        }
        .frame(width: size, height: size)
        .background(AppTheme.accent.opacity(0.12))
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            if p.online { Circle().fill(.green).frame(width: 9, height: 9).overlay(Circle().stroke(.background, lineWidth: 2)) }
        }
    }

    private func avatar(_ p: FluxChatFriend, size: CGFloat) -> some View {
        Group {
            if let url = URL(string: p.avatar_url), !p.avatar_url.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: Image(systemName: p.icon).resizable().scaledToFit().padding(size * 0.25)
                    }
                }
            } else {
                Image(systemName: p.icon).resizable().scaledToFit().padding(size * 0.25)
            }
        }
        .frame(width: size, height: size)
        .background(AppTheme.accent.opacity(0.12))
        .clipShape(Circle())
    }
}

private struct FluxMessageRow: View {
    let message: FluxChatMessage
    let currentProfileID: Int?

    var body: some View {
        HStack(alignment: .bottom) {
            if message.sender.id == currentProfileID { Spacer(minLength: 30) }
            VStack(alignment: message.sender.id == currentProfileID ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(message.sender.display_name).font(.caption.bold())
                    if message.sender.is_admin {
                        Text("✓ \(message.sender.admin_label.isEmpty ? "Admin" : message.sender.admin_label)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color(hex: message.sender.admin_color).opacity(0.22))
                            .clipShape(Capsule())
                    }
                }
                Text(message.body)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(message.sender.id == currentProfileID ? AppTheme.accent.opacity(0.20) : Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                if let attachment = message.attachment {
                    Link(destination: URL(string: attachment.url)!) {
                        Label(attachment.name, systemImage: message.message_type == "image" ? "photo" : message.message_type == "video" ? "video" : "doc")
                            .font(.caption)
                    }
                }
                HStack(spacing: 4) {
                    if message.is_pinned { Image(systemName: "pin.fill") }
                    Text(message.created_at).font(.caption2).foregroundStyle(.secondary)
                    if message.edited { Text("đã sửa").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            if message.sender.id != currentProfileID { Spacer(minLength: 30) }
        }
    }
}

// MARK: - Account

struct FluxAccountView: View {
    @ObservedObject var service: FluxChatService
    @State private var name = ""
    @State private var icon = "person.crop.circle.fill"
    @State private var avatar = ""
    @State private var password = ""
    @State private var email = ""
    @State private var telegram = ""
    @State private var notifications = true
    @State private var recoveryKey = ""
    @State private var recoveryCode = ""
    @State private var recoveryPassword = ""
    @State private var recoveryChannel = "email"
    @State private var showPasswordWarning = false
    @State private var friendNotificationState: [Int: Bool] = [:]
    @State private var friendKey = ""
    @State private var showAddFriend = false
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var isUploadingAvatar = false

    private func remainingTime(from raw: String?, now: Date) -> String {
        guard let raw, !raw.isEmpty else { return "Vĩnh viễn" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let expiry = formatter.date(from: raw) else { return raw }
        let seconds = Int(expiry.timeIntervalSince(now))
        if seconds <= 0 { return "Đã hết hạn" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let secs = seconds % 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m \(secs)s" }
        return "\(minutes)m \(secs)s"
    }

    var body: some View {
        Form {
            if let p = service.profile {
                Section {
                    VStack(spacing: 8) {
                        PhotosPicker(selection: $selectedAvatarItem, matching: .images, photoLibrary: .shared()) {
                            ZStack(alignment: .bottomTrailing) {
                                if let url = URL(string: p.avatar_url), !p.avatar_url.isEmpty {
                                    AsyncImage(url: url) { phase in
                                        if case .success(let image) = phase {
                                            image.resizable().scaledToFill()
                                        } else {
                                            Image(systemName: p.icon).resizable().scaledToFit().padding(28)
                                        }
                                    }
                                    .frame(width: 110, height: 110).clipShape(Circle())
                                } else {
                                    Image(systemName: p.icon).font(.system(size: 68)).frame(width: 110, height: 110)
                                        .background(AppTheme.accent.opacity(0.12)).clipShape(Circle())
                                }
                                Image(systemName: "camera.fill")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                    .padding(8)
                                    .background(AppTheme.accent, in: Circle())
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isUploadingAvatar)

                        if isUploadingAvatar {
                            ProgressView("Đang tải ảnh…")
                                .font(.caption)
                        } else {
                            Text("Chạm vào avatar để chọn ảnh trực tiếp")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(p.display_name).font(.title2.bold())
                        if p.is_admin {
                            Text("✓ \(p.admin_label.isEmpty ? "Admin" : p.admin_label)")
                                .font(.caption.bold())
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color(hex: p.admin_color).opacity(0.2))
                                .clipShape(Capsule())
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(p.lifetime ? "Key: Vĩnh viễn" : "Còn lại: \(remainingTime(from: p.expires_at, now: context.date))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }

                Section("Thông tin") {
                    TextField("Tên hiển thị", text: $name)
                    TextField("Icon SF Symbol", text: $icon)
                    TextField("Avatar URL (HTTPS)", text: $avatar)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: avatar) { _ in }
                    Text("Bạn có thể chọn ảnh trực tiếp ở avatar. URL chỉ là tùy chọn nâng cao.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("Mật khẩu mới", text: $password)
                    TextField("Email khôi phục", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    TextField("Telegram ID khôi phục", text: $telegram)
                        .keyboardType(.numberPad)
                }

                Section("Khôi phục mật khẩu") {
                    TextField("Key cần khôi phục", text: $recoveryKey)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Picker("Kênh", selection: $recoveryChannel) {
                        Text("Email").tag("email")
                        Text("Telegram").tag("telegram")
                    }
                    Button("Gửi mã khôi phục") {
                        Task {
                            let message = await service.requestRecovery(
                                key: recoveryKey, channel: recoveryChannel
                            )
                            if let message { service.errorMessage = message }
                        }
                    }
                    TextField("Mã 6 số", text: $recoveryCode)
                        .keyboardType(.numberPad)
                    SecureField("Mật khẩu mới", text: $recoveryPassword)
                    Button("Đặt lại mật khẩu") {
                        Task {
                            let message = await service.resetRecovery(
                                key: recoveryKey,
                                code: recoveryCode,
                                password: recoveryPassword
                            )
                            if let message { service.errorMessage = message }
                        }
                    }
                }

                Section("Thông báo") {
                    Toggle("Thông báo toàn bộ Chat", isOn: $notifications)
                    if !service.friends.filter({ $0.status == "accepted" }).isEmpty {
                        ForEach(service.friends.filter({ $0.status == "accepted" })) { friend in
                            Toggle("Tin nhắn riêng: \(friend.display_name)", isOn: Binding(
                                get: { friendNotificationState[friend.id] ?? friend.notifications_enabled_for_me },
                                set: { value in
                                    friendNotificationState[friend.id] = value
                                    Task { await service.setNotifications(enabled: value, scope: "private", target: String(friend.id)) }
                                }
                            ))
                        }
                    }
                }

                Section {
                    Button("Lưu thay đổi") {
                        Task {
                            let isFirstPassword = password.count >= 6 && !(service.profile?.has_password ?? false)
                            await service.updateProfile(
                                displayName: name, icon: icon, avatarURL: avatar,
                                password: password, email: email, telegram: telegram
                            )
                            await service.setNotifications(enabled: notifications)
                            if isFirstPassword && email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && telegram.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                showPasswordWarning = true
                            }
                            password = ""
                        }
                    }
                    Button("Đăng xuất", role: .destructive) { service.logout() }
                }
            }
        }
        .navigationTitle("Tài Khoản")
        .alert("Lưu ý bảo mật", isPresented: $showPasswordWarning) {
            Button("Đã hiểu", role: .cancel) {}
        } message: {
            Text("Hãy thêm email hoặc id telegram để tránh quên mật khẩu, quên mật khẩu user sẽ tự chịu hoàn toàn trách nhiệm")
        }
        .onChange(of: selectedAvatarItem) { item in
            guard let item else { return }
            Task {
                isUploadingAvatar = true
                defer { isUploadingAvatar = false }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw ChatAPIError.server("Không đọc được ảnh đã chọn")
                    }
                    let type = item.supportedContentTypes.first
                    let mime = type?.preferredMIMEType ?? "image/jpeg"
                    let ext = type?.preferredFilenameExtension ?? "jpg"
                    await service.uploadAvatar(data: data, mime: mime, filename: "avatar.\(ext)")
                    selectedAvatarItem = nil
                    if let p = service.profile {
                        avatar = p.avatar_url
                    }
                } catch {
                    service.errorMessage = error.localizedDescription
                }
            }
        }
        .onAppear {
            guard let p = service.profile else { return }
            name = p.display_name
            icon = p.icon
            avatar = p.avatar_url
            notifications = p.notifications_enabled
            friendNotificationState = Dictionary(uniqueKeysWithValues: service.friends.filter({ $0.status == "accepted" }).map { ($0.id, $0.notifications_enabled_for_me) })
        }
    }
}

struct FluxFeatureNotice: Codable, Identifiable, Equatable {
    let id: String
    let feature: String
    let title: String
    let content: String
    let enabled: Bool
    let updated_at: String
    let image_url: String?
    let button_label: String?
    let button_url: String?
    let buttons: [NoticeButton]?

    struct NoticeButton: Codable, Identifiable, Equatable { let id: String; let label: String; let url: String; let sort_order: Int? }

    enum CodingKeys: String, CodingKey {
        case id, feature, title, content, enabled, updated_at, image_url, button_label, button_url, buttons
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        feature = try c.decodeIfPresent(String.self, forKey: .feature) ?? "app"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Thông báo"
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        updated_at = try c.decodeIfPresent(String.self, forKey: .updated_at) ?? ""
        image_url = try c.decodeIfPresent(String.self, forKey: .image_url)
        button_label = try c.decodeIfPresent(String.self, forKey: .button_label)
        button_url = try c.decodeIfPresent(String.self, forKey: .button_url)
        buttons = try c.decodeIfPresent([NoticeButton].self, forKey: .buttons)
    }
}

private struct FluxFeatureNoticeResponse: Codable {
    let ok: Bool
    let items: [FluxFeatureNotice]
}

@MainActor
final class FeatureNoticeService: ObservableObject {
    static let shared = FeatureNoticeService()
    @Published private(set) var notice: FluxFeatureNotice?
    private let endpoint = URL(string: "https://appfluxcore.site/api/feature_notices.php")!
    private let session: URLSession

    private init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 12
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
    }

    func load(feature: String = "app") async {
        do {
            var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "feature", value: feature)]
            var req = URLRequest(url: comps.url!)
            req.httpMethod = "GET"
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return }
            let decoded = try JSONDecoder().decode(FluxFeatureNoticeResponse.self, from: data)
            notice = decoded.items.first(where: { $0.enabled })
        } catch {
            // Notice is non-critical; the App page must remain usable offline.
        }
    }
}

struct FeatureNoticeOverlay<Content: View>: View {
    let content: Content
    @StateObject private var service = FeatureNoticeService.shared
    @State private var presented = false
    @Environment(\.openURL) private var openURL
    private let dismissalKey = "FluxCore.dismissedNoticeIdentity.v1"

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    private func dismiss(_ notice: FluxFeatureNotice) {
        let identity = "\(notice.id)|\(notice.updated_at)"
        UserDefaults.standard.set(identity, forKey: dismissalKey)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { presented = false }
    }

    var body: some View {
        ZStack {
            content
            if presented, let n = service.notice {
                Color.black.opacity(0.42).ignoresSafeArea()
                VStack(spacing: 14) {
                    HStack {
                        Image(systemName: "megaphone.fill").foregroundStyle(AppTheme.accent)
                        Text(n.title).font(.headline.bold())
                        Spacer()
                        Button { dismiss(n) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                    }
                    if let raw = n.image_url, let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFit().frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 14))
                            } else if phase.error != nil {
                                EmptyView()
                            } else {
                                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
                            }
                        }
                    }
                    Text(n.content).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    let orderedButtons = (n.buttons ?? []).sorted { ($0.sort_order ?? 0) < ($1.sort_order ?? 0) }
                    if !orderedButtons.isEmpty {
                        ForEach(orderedButtons) { item in
                            if let url = URL(string: item.url), url.scheme?.lowercased() == "https", url.host != nil,
                               !item.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Button { openURL(url) } label: {
                                    Label(String(item.label.prefix(80)), systemImage: "arrow.up.right")
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }.buttonStyle(.borderedProminent)
                            }
                        }
                    } else if let label = n.button_label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
                              let rawURL = n.button_url, let url = URL(string: rawURL), url.scheme?.lowercased() == "https", url.host != nil {
                        Button { openURL(url) } label: { Label(String(label.prefix(80)), systemImage: "arrow.up.right").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.borderedProminent)
                    }
                    Button("Đã hiểu") { dismiss(n) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
                .padding(20)
                .frame(maxWidth: 520)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AppTheme.accent.opacity(0.35), lineWidth: 1))
                .shadow(radius: 28)
                .padding(20)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .task {
            await service.load(feature: "app")
            guard let notice = service.notice else { return }
            let identity = "\(notice.id)|\(notice.updated_at)"
            guard UserDefaults.standard.string(forKey: dismissalKey) != identity else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { presented = true }
        }
    }
}

// MARK: - Global Key Password Gate

struct FluxPasswordGateView: View {
    let key: String
    @ObservedObject var service: FluxChatService
    @State private var password = ""
    @State private var showError = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.58).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
                Text("Xác thực Key")
                    .font(.title2.bold())
                Text("Key này đã được bảo vệ bằng mật khẩu. Vui lòng nhập mật khẩu để tiếp tục vào App.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "key.fill")
                    Text(key).font(.headline.monospaced())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                SecureField("Mật khẩu Key", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task {
                        let ok = await service.unlockApp(key: key, password: password)
                        if !ok { showError = true }
                    }
                } label: {
                    HStack {
                        if service.isLoading { ProgressView().tint(.white) }
                        Text("Mở khóa App")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty || service.isLoading)
                if let error = service.errorMessage, showError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("Nếu quên mật khẩu, vào Chat → Tài Khoản → Khôi phục mật khẩu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(AppTheme.accent.opacity(0.35), lineWidth: 1))
            .shadow(radius: 30)
            .padding(20)
        }
        .interactiveDismissDisabled()
        .onChange(of: service.errorMessage) { _ in
            if service.errorMessage != nil { showError = true }
        }
    }
}
