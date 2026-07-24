import Foundation
import Testing
@testable import KotobaneCore

@Test func requestEncodingMatchesNDJSONContract() throws {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let request = HelperRequest(
        id: id,
        action: "transcribe",
        audioPath: "/private/tmp/audio.wav",
        language: "Turkish",
        model: "qwen3-asr-0.6b"
    )

    let line = try HelperCodec.encode(request)

    #expect(
        line
            == #"{"action":"transcribe","audioPath":"/private/tmp/audio.wav","id":"00000000-0000-0000-0000-000000000001","language":"Turkish","model":"qwen3-asr-0.6b"}"#
                + "\n"
    )
    #expect(line.filter { $0 == "\n" }.count == 1)
}

@Test func completedResponseDecodingPreservesFields() throws {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let line = Data(
        #"{"detectedLanguage":"tr","durationSeconds":1.25,"id":"00000000-0000-0000-0000-000000000001","status":"completed","text":" şey, API'yi düzeltelim "}"#
            .utf8
    )

    let response = try HelperCodec.decode(line, expectedID: id)

    #expect(
        response
            == .completed(
                .init(
                    id: id,
                    text: " şey, API'yi düzeltelim ",
                    detectedLanguage: "tr",
                    durationSeconds: 1.25
                )
            )
    )
}

@Test func failedResponseDecodingPreservesCodeAndMessage() throws {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let line = Data(
        #"{"code":"model_unavailable","id":"00000000-0000-0000-0000-000000000001","message":"Install the selected model","status":"failed"}"#
            .utf8
    )

    let response = try HelperCodec.decode(line, expectedID: id)

    #expect(
        response
            == .failed(
                .init(
                    id: id,
                    code: "model_unavailable",
                    message: "Install the selected model"
                )
            )
    )
}

@Test func responseWithMismatchedIDIsRejected() {
    let expected = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let actual = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let line = Data(
        #"{"detectedLanguage":"tr","durationSeconds":1,"id":"00000000-0000-0000-0000-000000000002","status":"completed","text":"Merhaba"}"#
            .utf8
    )

    #expect(throws: HelperCodecError.mismatchedID(expected: expected, actual: actual)) {
        try HelperCodec.decode(line, expectedID: expected)
    }
}

@Test func malformedResponseIsRejected() {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    #expect(throws: HelperCodecError.malformedResponse) {
        try HelperCodec.decode(Data("{".utf8), expectedID: id)
    }
}

@Test func unknownResponseStatusIsRejected() {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let line = Data(
        #"{"id":"00000000-0000-0000-0000-000000000001","status":"progress"}"#.utf8
    )

    #expect(throws: HelperCodecError.unknownStatus("progress")) {
        try HelperCodec.decode(line, expectedID: id)
    }
}

@Test(arguments: [
    ("audioPath", "/private/tmp/audio.wav", "tr", "small"),
    ("language", "/a", "Turkish language", "small"),
    ("model", "/a", "tr", "qwen3-asr-0.6b"),
])
func requestFieldsHaveUTF8ByteLimits(
    _ field: String,
    audioPath: String,
    language: String,
    model: String
) {
    let request = HelperRequest(
        id: UUID(),
        action: "transcribe",
        audioPath: audioPath,
        language: language,
        model: model
    )
    let limits = HelperProcessLimits(
        maximumAudioPathBytes: 8,
        maximumLanguageBytes: 8,
        maximumModelBytes: 8
    )

    #expect(throws: HelperCodecError.fieldTooLarge(field: field, maximumBytes: 8)) {
        try HelperCodec.encode(request, limits: limits)
    }
}

@Test func encodedRequestHasATotalByteLimit() {
    let request = HelperRequest(
        id: UUID(),
        action: "transcribe",
        audioPath: "/tmp/a.wav",
        language: "tr",
        model: "small"
    )
    let limits = HelperProcessLimits(maximumRequestBytes: 32)

    #expect(throws: HelperCodecError.requestTooLarge(maximumBytes: 32)) {
        try HelperCodec.encode(request, limits: limits)
    }
}
