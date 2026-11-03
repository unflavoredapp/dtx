import Foundation

/// A function-callable tool the model can invoke in any conversation (no attachment required) to generate an
/// image — a UI mockup, an icon, an illustration — and show it inline in the chat.
///
/// Generation runs on the server through stable-diffusion.cpp's own `sd-server` binary — it ships an
/// OpenAI-compatible `/v1/images/generations` endpoint out of the box, so there's no custom wrapper needed,
/// just an Apache proxy path (see the server-setup notes) pointing at it.
enum AiImageGen {
    static let endpoint = URL(string: "https://ai.decrypt.team/sdgen/v1/images/generations")!

    static let schema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "generate_image",
            "description": "Generates an image — a UI mockup, app icon, or illustration — from a text prompt and shows it to the person in the chat. Use this whenever they ask to see, design, mock up, or visualize something. Generation runs on CPU and takes roughly 20-60 seconds.",
            "parameters": [
                "type": "object",
                "properties": [
                    "prompt": ["type": "string", "description": "A clear, detailed description of the image to generate."],
                ],
                "required": ["prompt"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    private struct Response: Decodable {
        struct Item: Decodable { let b64_json: String }
        let data: [Item]
    }

    static func generate(prompt: String) async throws -> Data {
        var request = URLRequest(url: endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "prompt": prompt, "n": 1, "size": "512x512", "output_format": "png",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ApiError.server("The image server answered with error \(code).", code)
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let b64 = decoded.data.first?.b64_json,
              let imageData = Data(base64Encoded: b64)
        else { throw ApiError.server("The image server's response wasn't in the expected format.", 0) }
        return imageData
    }

    /// Pulls the "prompt" field out of a tool call's raw (possibly empty/partial) JSON arguments string.
    static func extractPrompt(_ argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prompt = obj["prompt"] as? String
        else { return "" }
        return prompt
    }
}
