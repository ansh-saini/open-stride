import Foundation

/// Talks to an Ollama server (`ollama serve`). Used on the Mac, the simulator, and as a fallback on device.
public struct OllamaClient: LLMClient {
    public var baseURL: URL
    public var model: String
    public var temperature: Double

    public init(baseURL: URL = URL(string: "http://localhost:11434")!, model: String = "gemma3:4b", temperature: Double = 0.2) {
        self.baseURL = baseURL
        self.model = model
        self.temperature = temperature
    }

    public var name: String { "\(model) (Ollama)" }

    public struct HTTPError: Error, CustomStringConvertible {
        public var status: Int
        public var body: String
        public var description: String { "Ollama HTTP \(status): \(body.prefix(200))" }
    }

    public func complete(system: String, user: String, schema: [String: any Sendable]) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "options": ["temperature": temperature],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if !schema.isEmpty { body["format"] = schema }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HTTPError(status: status, body: String(decoding: data, as: UTF8.self)) }

        struct Reply: Decodable {
            struct Message: Decodable { var content: String }
            var message: Message
        }
        return try JSONDecoder().decode(Reply.self, from: data).message.content
    }
}
