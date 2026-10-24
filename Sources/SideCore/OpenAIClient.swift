import Foundation

public struct SideAPIError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public final class OpenAIClient: @unchecked Sendable {
    private let key: String
    private let session: URLSession
    public let model: String
    public init(key: String, model: String = "gpt-6.1-sol", session: URLSession = .shared) {
        self.key = key; self.model = model; self.session = session
    }
    private func request(_ path: String, body: Data, contentType: String = "application/json") async throws -> Data {
        guard !key.isEmpty else { throw SideAPIError("Add an OpenAI API key in Settings.") }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/\(path)")!)
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type"); request.httpBody = body
        let result:(Data,URLResponse)
        do {result=try await session.data(for:request)}
        catch {
            // URLSession uses URLError.cancelled for a cancelled Swift task.
            if Task.isCancelled{throw CancellationError()}
            throw error
        }
        let (data,response)=result
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SideAPIError("No response from OpenAI.") }
        guard (200...299).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (object?["error"] as? [String: Any])?["message"] as? String ?? "OpenAI returned HTTP \(http.statusCode)."
            throw SideAPIError(message.replacingOccurrences(of: key, with: "[redacted]"))
        }
        return data
    }
    public func respond(input: [[String: Any]], allowWeb: Bool = true, tools: [[String: Any]]? = nil) async throws -> [String: Any] {
        let selectedTools = tools ?? SceneSchema.tools.filter { allowWeb || ($0["type"] as? String != "web_search") }
        let body: [String: Any] = [
            "model": model, "instructions": SceneSchema.instructions,
            "input": input, "tools": selectedTools, "parallel_tool_calls": false,
            "reasoning": ["effort": "low"], "max_output_tokens": 14000,
            "store": false, "include": ["reasoning.encrypted_content"]
        ]
        let data = try await request("responses", body: JSONSerialization.data(withJSONObject: body))
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SideAPIError("OpenAI returned an unreadable response.")
        }
        if result["status"] as? String == "incomplete" {
            throw SideAPIError("Sol ran out of room for this drawing. Ask for one part at a time.")
        }
        return result
    }
    public func transcribe(file: URL) async throws -> String {
        let boundary = "Side-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n")
        let ext=file.pathExtension.lowercased(),mime=ext == "wav" ? "audio/wav":"audio/mp4"
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.\(ext)\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(try Data(contentsOf: file)); append("\r\n--\(boundary)--\r\n")
        let data = try await request("audio/transcriptions", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { throw SideAPIError("Speech could not be transcribed.") }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SideAPIError("No speech was heard. Try again, or type your question.") }
        return clean
    }
    public func speech(_ text: String) async throws -> Data {
        let body: [String: Any] = ["model": "gpt-4o-mini-tts", "voice": "coral", "input": String(text.prefix(4000)),
            "instructions": "Speak like a patient, friendly tutor. Natural pace, clear explanations, no theatrical delivery.",
            "response_format": "mp3"]
        return try await request("audio/speech", body: JSONSerialization.data(withJSONObject: body))
    }
    public static func outputText(_ response: [String: Any]) -> String {
        let outputs = response["output"] as? [[String: Any]] ?? []
        return outputs.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    public static func sources(_ response: [String: Any]) -> [(title: String, url: String)] {
        let outputs = response["output"] as? [[String: Any]] ?? []
        return outputs.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .flatMap { $0["annotations"] as? [[String: Any]] ?? [] }
            .compactMap { annotation in
                guard let url = annotation["url"] as? String else { return nil }
                return (annotation["title"] as? String ?? url, url)
            }
    }
}
