import Foundation

/// A function-callable tool the model can invoke in any conversation (no attachment required) to generate an
/// image — a UI mockup, an icon, an illustration — and show it inline in the chat.
///
/// Generation runs on the server through stable-diffusion.cpp's own `sd-server` binary — it ships an
/// OpenAI-compatible `/v1/images/generations` endpoint out of the box, so there's no custom wrapper needed,
/// just an Apache proxy path (see the server-setup notes) pointing at it.
enum AiImageGen {
    static let endpoint = URL(string: "https://ai.decrypt.team/sdgen/v1/images/generations")!
    /// img2img — takes an input image plus a prompt. Used for "redesign / mock up this image" requests.
    static let editsEndpoint = URL(string: "https://ai.decrypt.team/sdgen/v1/images/edits")!

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
        return try decodeImage(from: data)
    }

    /// img2img: redraw/redesign an existing image guided by a prompt, via sd-server's OpenAI-style
    /// `/v1/images/edits` endpoint (multipart form, `image[]` + `prompt`).
    static func editImage(prompt: String, imageData: Data) async throws -> Data {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: editsEndpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("prompt", prompt)
        field("size", "512x512")
        field("output_format", "png")
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image[]\"; filename=\"input.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ApiError.server("The image server answered with error \(code).", code)
        }
        return try decodeImage(from: data)
    }

    private static func decodeImage(from data: Data) throws -> Data {
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let b64 = decoded.data.first?.b64_json,
              let imageData = Data(base64Encoded: b64)
        else { throw ApiError.server("The image server's response wasn't in the expected format.", 0) }
        return imageData
    }

    /// Pulls a `[GENERATE]…[/GENERATE]` (or `[GENERATE]…` to end) image-prompt marker out of the vision
    /// model's reply. The vision model can't call tools, so this marker is how it asks for an image instead.
    static func extractGenerateDirective(_ content: String) -> String? {
        guard let start = content.range(of: "[GENERATE]") else { return nil }
        let after = content[start.upperBound...]
        let prompt: String
        if let end = after.range(of: "[/GENERATE]") {
            prompt = String(after[..<end.lowerBound])
        } else {
            prompt = String(after)
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
