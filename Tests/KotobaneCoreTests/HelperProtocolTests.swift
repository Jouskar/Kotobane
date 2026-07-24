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
