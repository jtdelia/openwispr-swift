import Foundation
import OpenWisprCore
import OpenWisprEngines

// Runs the real Built-in engines once, outside the app:
//   openwispr-smoke <file.wav> [--model <id>] [--models-dir <dir>] [--language <code>] [--cleanup]
// `--cleanup` also sends the transcript through Apple's chat model.

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}

guard arguments.count > 1, !arguments[1].hasPrefix("--") else {
    FileHandle.standardError.write(Data("usage: openwispr-smoke <file.wav> [--model <id>] [--models-dir <dir>] [--language <code>] [--cleanup]\n".utf8))
    exit(2)
}

let wav = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
let model = option("--model") ?? appleModelId
let language = option("--language") ?? "en"
let modelsDirectory = URL(fileURLWithPath: option("--models-dir") ?? FileManager.default.temporaryDirectory.path, isDirectory: true)
let engines = LocalEngines(modelsDirectory: modelsDirectory, requestsSpeechAuthorization: false) { progress in
    FileHandle.standardError.write(Data("\(progress.label)\n".utf8))
}

let status = try await engines.status(language: language, speechToText: model == appleModelId ? nil : model, chat: nil)
print("Apple speech-to-text: \(status.appleSpeech.available ? "available (\(status.appleSpeech.locale ?? "no locale"))" : status.appleSpeech.reason ?? "unavailable")")
print("Apple chat: \(status.appleChat.available ? "available, \(status.appleChat.contextSize ?? 0) tokens" : status.appleChat.reason ?? "unavailable")")

let started = ContinuousClock.now
let transcription = try await engines.transcribe(model: model, wav: wav, language: language, prompt: "", segments: true)
print("Transcript (\(ContinuousClock.now - started)): \(transcription.text.trimmingCharacters(in: .whitespaces))")
for segment in transcription.segments ?? [] {
    print(String(format: "  %6.2f–%6.2f %@", segment.start, segment.end, segment.text))
}

if arguments.contains("--cleanup"), status.appleChat.available {
    let messages = cleanupMessages(CleanupInput(
        transcript: transcription.text, style: .casual, category: .other, appName: "", beforeText: "", dictionary: [], userName: ""
    ))
    let cleaned = try await engines.complete(model: appleModelId, messages: messages, maxTokens: cleanupMaxTokens(transcription.text))
    print("Cleaned up: \(sanitizeCleanup(cleaned, transcript: transcription.text, beforeText: ""))")
}
await engines.stop()
