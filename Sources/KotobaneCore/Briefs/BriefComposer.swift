public enum BriefComposer {
    public static func compose(intent: CaptureIntent, transcript: String) -> String {
        if intent == .transcriptOnly {
            return transcript
        }

        let template = IntentTemplate.template(for: intent)
        let checklist = template.checklist.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        return """
        # \(template.heading)

        \(template.instruction)

        ## Desired outcome

        \(template.outcome)

        ## Raw transcript

        \(transcript)

        ## Requested response

        \(checklist)
        """
    }
}

private struct IntentTemplate {
    let heading: String
    let instruction: String
    let outcome: String
    let checklist: [String]

    static func template(for intent: CaptureIntent) -> Self {
        switch intent {
        case .brainstorm:
            Self(
                heading: "Brainstorm captured in Kotobane",
                instruction: "Please help me turn the following spoken brainstorm into a clear next step.",
                outcome: "Clarify the idea, identify assumptions and missing decisions, then propose an actionable plan.",
                checklist: [
                    "Concise summary",
                    "Decisions and constraints",
                    "Open questions",
                    "Recommended next actions"
                ]
            )
        case .task:
            Self(
                heading: "Task captured in Kotobane",
                instruction: "Please help me turn the following spoken task into a clear, actionable task.",
                outcome: "Define the task, its constraints, and the next actions needed to complete it.",
                checklist: [
                    "Task summary",
                    "Acceptance criteria",
                    "Constraints and dependencies",
                    "Recommended next actions"
                ]
            )
        case .projectIdea:
            Self(
                heading: "Project idea captured in Kotobane",
                instruction: "Please help me turn the following spoken project idea into a clear project proposal.",
                outcome: "Clarify the problem, intended outcome, scope, and the first steps for validating the idea.",
                checklist: [
                    "Project summary",
                    "Problem and intended outcome",
                    "Scope, assumptions, and risks",
                    "Recommended next actions"
                ]
            )
        case .meetingNote:
            Self(
                heading: "Meeting note captured in Kotobane",
                instruction: "Please help me turn the following spoken meeting note into a clear record and follow-up plan.",
                outcome: "Capture the discussion, decisions, owners, and follow-up actions accurately.",
                checklist: [
                    "Concise summary",
                    "Decisions made",
                    "Action items and owners",
                    "Open questions and follow-up"
                ]
            )
        case .freeform:
            Self(
                heading: "Note captured in Kotobane",
                instruction: "Please help me organize the following spoken note into a useful next step.",
                outcome: "Preserve the meaning of the note, identify its key points, and suggest an appropriate next action.",
                checklist: [
                    "Concise summary",
                    "Key points",
                    "Open questions",
                    "Recommended next actions"
                ]
            )
        case .transcriptOnly:
            fatalError("Transcript-only intent does not use a template.")
        }
    }
}
