import Foundation
import FoundationModels
import OpenWisprCore

/// Apple's on-device Foundation Models chat model. The user can turn Apple Intelligence on or off at
/// any time, so availability is read on every request.
struct AppleChat: ChatEngine {
    /// What Apple's model answers, as text rather than an error, when it declines.
    private static let textRefusal = "Unable to work with that request."

    /// Relaxed guardrails meant for transforming text the user supplied, which is all OpenWispr asks for.
    private static func model() -> SystemLanguageModel {
        SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    func status() -> BuiltInStatus.AppleChat {
        let model = Self.model()
        switch model.availability {
        case .available:
            return BuiltInStatus.AppleChat(available: true, contextSize: model.contextSize)
        case let .unavailable(reason):
            let (message, fix) = Self.describe(reason)
            return BuiltInStatus.AppleChat(available: false, reason: message, fix: fix)
        }
    }

    func load() throws {
        let model = Self.model()
        try Self.ensureAvailable(model)
        LanguageModelSession(model: model).prewarm()
    }

    /// The system owns Apple's model.
    func unload() async {}

    func complete(_ messages: [ChatMessage], maxTokens wanted: Int) async throws -> String {
        let model = Self.model()
        try Self.ensureAvailable(model)
        let instructions = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let prompt = Self.prompt(messages.filter { $0.role != .system })
        let maxTokens = try await Self.answerTokens(model, instructions: instructions, prompt: prompt, wanted: wanted)
        // A fresh session per request: a session keeps its transcript, which would fill the context.
        let session = LanguageModelSession(model: model, instructions: instructions.isEmpty ? nil : instructions)
        let response: LanguageModelSession.Response<String>
        do {
            response = try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxTokens))
        } catch {
            throw Self.modelError(error)
        }
        // Foundation Models stops at the cap without an error, so a full answer budget means it was cut off.
        if response.usage.output.totalTokenCount >= maxTokens {
            throw ModelError.contextExceeded("The answer didn't fit in \(maxTokens) tokens")
        }
        if response.content.trimmingCharacters(in: .whitespacesAndNewlines) == Self.textRefusal {
            throw ModelError.refused("Apple's chat model declined")
        }
        return response.content
    }

    private static func answerTokens(_ model: SystemLanguageModel, instructions: String, prompt: String, wanted: Int) async throws -> Int {
        let used: Int
        do {
            let instructionTokens = instructions.isEmpty ? 0 : try await model.tokenCount(for: Instructions(instructions))
            used = try await instructionTokens + model.tokenCount(for: prompt)
        } catch {
            throw modelError(error)
        }
        return try answerBudget(used: used, contextSize: model.contextSize, wanted: wanted, modelName: "Apple's chat model")
    }

    /// Earlier turns are flattened into the prompt; Cleanup and summaries send a single user message.
    private static func prompt(_ messages: [ChatMessage]) -> String {
        if messages.count == 1 { return messages[0].content }
        return messages.map { "\($0.role.rawValue.capitalized): \($0.content)" }.joined(separator: "\n\n")
    }

    private static func ensureAvailable(_ model: SystemLanguageModel) throws {
        if case let .unavailable(reason) = model.availability {
            throw ModelError.unavailable(describe(reason).message)
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> (message: String, fix: BuiltInStatus.AppleChatFix?) {
        switch reason {
        case .appleIntelligenceNotEnabled: ("Apple Intelligence is off", .turnOnAppleIntelligence)
        case .deviceNotEligible: ("This Mac can't run Apple Intelligence", nil)
        case .modelNotReady: ("Apple Intelligence is still downloading its model", .wait)
        @unknown default: ("Apple's chat model isn't available", nil)
        }
    }

    private static func modelError(_ error: any Error) -> ModelError {
        if let error = error as? ModelError { return error }
        if let error = error as? LanguageModelError {
            switch error {
            case let .contextSizeExceeded(context):
                return .contextExceeded("Too long for Apple's chat model (\(context.tokenCount) of \(context.contextSize) tokens)")
            case .guardrailViolation, .refusal:
                return .refused("Apple's chat model declined")
            case .unsupportedLanguageOrLocale:
                return .unsupportedLanguage("Apple's chat model doesn't support this language")
            default:
                return .modelFailed(error.localizedDescription)
            }
        }
        if error is SystemLanguageModel.Error {
            return .unavailable("Apple's chat model isn't available")
        }
        return .modelFailed(error.localizedDescription)
    }
}
