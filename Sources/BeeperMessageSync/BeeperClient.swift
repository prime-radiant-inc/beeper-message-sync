import Foundation

struct BeeperClient: Sendable {
    let baseURL: String
    let token: String
    let timeoutInterval: TimeInterval

    init(baseURL: String, token: String, timeoutInterval: TimeInterval = 30) {
        self.baseURL = baseURL
        self.token = token
        self.timeoutInterval = timeoutInterval
    }

    // MARK: - Accounts

    func listAccounts() async throws -> [Account] {
        return try await get(path: "/v1/accounts")
    }

    // MARK: - Chats

    /// List chats using /v1/chats/search which returns all chats
    /// (/v1/chats silently caps results at ~25 per account)
    func listChats(
        limit: Int? = nil,
        cursor: String? = nil,
        direction: String? = nil,
        accountIDs: [String]? = nil
    ) async throws -> ChatListResponse {
        var query: [(String, String)] = []
        query.append(("limit", String(limit ?? 200)))
        if let cursor { query.append(("cursor", cursor)) }
        if let direction { query.append(("direction", direction)) }
        if let accountIDs {
            for id in accountIDs { query.append(("accountIDs", id)) }
        }
        return try await get(path: "/v1/chats/search", query: query)
    }

    // MARK: - Messages

    func listMessages(
        chatID: String,
        limit: Int? = nil,
        cursor: String? = nil,
        direction: String? = nil
    ) async throws -> MessageListResponse {
        let encodedChatID = chatID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? chatID
        var query: [(String, String)] = []
        if let limit { query.append(("limit", String(limit))) }
        if let cursor { query.append(("cursor", cursor)) }
        if let direction { query.append(("direction", direction)) }
        return try await get(
            path: "/v1/chats/\(encodedChatID)/messages", query: query
        )
    }

    // MARK: - Assets

    func downloadAsset(url assetURL: String) async throws -> AssetDownloadResponse {
        return try await post(
            path: "/v1/assets/download",
            body: AssetDownloadRequest(url: assetURL)
        )
    }

    // MARK: - HTTP helpers

    private func get<T: Decodable>(
        path: String,
        query: [(String, String)] = []
    ) async throws -> T {
        var components = URLComponents(string: baseURL + path)!
        if !query.isEmpty {
            components.queryItems = query.map {
                URLQueryItem(name: $0.0, value: $0.1)
            }
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = timeoutInterval
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable, B: Encodable>(
        path: String,
        body: B
    ) async throws -> T {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutInterval
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BeeperError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BeeperError.httpError(statusCode: http.statusCode, body: body)
        }
    }
}

enum BeeperError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Beeper API"
        case .httpError(let code, let body):
            return "Beeper API error \(code): \(body)"
        }
    }
}
