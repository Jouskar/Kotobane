import Foundation

public struct HelperRequest: Equatable, Sendable {
    public let id: UUID
    public let action: String
    public let audioPath: String
    public let language: String
    public let model: String

    public init(
        id: UUID,
        action: String,
        audioPath: String,
        language: String,
        model: String
    ) {
        self.id = id
        self.action = action
        self.audioPath = audioPath
        self.language = language
        self.model = model
    }
}

public enum HelperResponse: Equatable, Sendable {
    case completed(Completed)
    case failed(Failed)

    public struct Completed: Equatable, Sendable {
        public let id: UUID
        public let text: String
        public let detectedLanguage: String
        public let durationSeconds: Double

        public init(
            id: UUID,
            text: String,
            detectedLanguage: String,
            durationSeconds: Double
        ) {
            self.id = id
            self.text = text
            self.detectedLanguage = detectedLanguage
            self.durationSeconds = durationSeconds
        }
    }

    public struct Failed: Equatable, Sendable {
        public let id: UUID
        public let code: String
        public let message: String

        public init(id: UUID, code: String, message: String) {
            self.id = id
            self.code = code
            self.message = message
        }
    }
}

public enum HelperCodecError: Error, Equatable, Sendable {
    case malformedResponse
    case unknownStatus(String)
    case mismatchedID(expected: UUID, actual: UUID)
}

public enum HelperCodec {
    public static func encode(_ request: HelperRequest) throws -> String {
        let envelope = EncodedRequest(
            id: request.id.uuidString.lowercased(),
            action: request.action,
            audioPath: request.audioPath,
            language: request.language,
            model: request.model
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                request,
                .init(codingPath: [], debugDescription: "JSON was not valid UTF-8")
            )
        }
        return json + "\n"
    }

    public static func decode(_ line: Data, expectedID: UUID) throws -> HelperResponse {
        let decoder = JSONDecoder()
        let envelope: ResponseEnvelope
        do {
            envelope = try decoder.decode(ResponseEnvelope.self, from: line)
        } catch {
            throw HelperCodecError.malformedResponse
        }

        guard envelope.id == expectedID else {
            throw HelperCodecError.mismatchedID(expected: expectedID, actual: envelope.id)
        }

        switch envelope.status {
        case "completed":
            do {
                let completed = try decoder.decode(CompletedResponse.self, from: line)
                return .completed(
                    .init(
                        id: completed.id,
                        text: completed.text,
                        detectedLanguage: completed.detectedLanguage,
                        durationSeconds: completed.durationSeconds
                    )
                )
            } catch {
                throw HelperCodecError.malformedResponse
            }
        case "failed":
            do {
                let failed = try decoder.decode(FailedResponse.self, from: line)
                return .failed(
                    .init(id: failed.id, code: failed.code, message: failed.message)
                )
            } catch {
                throw HelperCodecError.malformedResponse
            }
        default:
            throw HelperCodecError.unknownStatus(envelope.status)
        }
    }
}

private struct EncodedRequest: Encodable {
    let id: String
    let action: String
    let audioPath: String
    let language: String
    let model: String
}

private struct ResponseEnvelope: Decodable {
    let id: UUID
    let status: String
}

private struct CompletedResponse: Decodable {
    let id: UUID
    let text: String
    let detectedLanguage: String
    let durationSeconds: Double
}

private struct FailedResponse: Decodable {
    let id: UUID
    let code: String
    let message: String
}
