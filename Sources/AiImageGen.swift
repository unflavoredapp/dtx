import Foundation

/// A function-callable tool the model can invoke in any conversation (no attachment required) to generate an
/// image — a UI mockup, an icon, an illustration — and show it inline in the chat. The actual generation runs
/// on the server behind a small HTTP wrapper around stable-diffusion.cpp (see the server-setup notes); this
/// just posts the prompt and gets image bytes back.
enum AiImageGen {
    static let endpoint = URL(string: "https://ai.decrypt.team/sdgen/generate")!

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

    static func generate(prompt: String) async throws -> Data {
        var request = URLRequest(url: endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": prompt])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ApiError.server("The image server answered with error \(code).", code)
        }
        return data
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
