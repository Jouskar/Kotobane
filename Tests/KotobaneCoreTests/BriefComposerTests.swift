import Testing
@testable import KotobaneCore

@Test func brainstormTemplateIsExactAndTranscriptIsVerbatim() {
    let transcript = "  Bunu değiştirme.\nİkinci satır.  "
    let expected = """
    # Brainstorm captured in Kotobane

    Please help me turn the following spoken brainstorm into a clear next step.

    ## Desired outcome

    Clarify the idea, identify assumptions and missing decisions, then propose an actionable plan.

    ## Raw transcript

    \(transcript)

    ## Requested response

    1. Concise summary
    2. Decisions and constraints
    3. Open questions
    4. Recommended next actions
    """

    #expect(BriefComposer.compose(intent: .brainstorm, transcript: transcript) == expected)
}

@Test func everyIntentHasAStableTemplate() {
    for intent in CaptureIntent.allCases {
        let output = BriefComposer.compose(intent: intent, transcript: "ham metin")
        #expect(output.contains("ham metin"))
        #expect(output.components(separatedBy: "ham metin").count == 2)
    }
}

@Test func transcriptOnlyReturnsTheEditedTranscriptExactly() {
    let transcript = "  İlk fikir.\n\nİkinci fikir.  "

    #expect(
        BriefComposer.compose(intent: .transcriptOnly, transcript: transcript) == transcript
    )
}
