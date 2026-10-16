import Foundation

enum UserQuestionState { case pending, answered, cancelled, expired }

struct UserQuestion: Identifiable {
    let id: UUID
    let sessionID: UUID
    let replyID: UUID
    let runID: UUID
    let spec: UserQuestionSpec
    var state: UserQuestionState = .pending
    var response: String?
    var createdAt = Date()
}

struct AgentCommandState {
    let sessionID: UUID
    let runID: UUID
    let blockID: UUID
    let replyID: UUID
    let stepID: UUID
    var deadline: Date
    var timedOut = false
    var interruptDeadline = Date.distantFuture
    var revision = 0
    var nativeControl = false
    var pauseStarted: Date?
}
