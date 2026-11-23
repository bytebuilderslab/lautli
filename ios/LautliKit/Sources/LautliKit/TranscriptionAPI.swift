import Foundation

/// Client side of `POST /api/v1/transcriptions` from epic #33: one compressed clip in, text out,
/// wrapped in the standard `{ data, error, meta }` envelope.
public enum TranscriptionAPI {
    public static let clipContentType = "audio/mp4"

    public static func request(serverURL: URL, clip: Data, requestID: DictationRequestID) -> URLRequest {
        var request = URLRequest(url: serverURL.appending(path: "api/v1/transcriptions"), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue(clipContentType, forHTTPHeaderField: "Content-Type")
        request.setValue(requestID.description, forHTTPHeaderField: "X-Request-ID")
        request.httpBody = clip
        return request
    }

    public static func transcript(statusCode: Int, body: Data) -> Result<String, DictationFailure> {
        guard (200..<300).contains(statusCode),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: body),
              let text = envelope.data?.text
        else { return .failure(.server) }
        return .success(text)
    }

    /// Accepts only http(s) URLs with a host; anything else would fail later with a vaguer error.
    public static func serverURL(from input: String) -> URL? {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host() != nil
        else { return nil }
        return url
    }

    private struct Envelope: Decodable {
        struct Transcription: Decodable { let text: String }
        let data: Transcription?
    }
}
