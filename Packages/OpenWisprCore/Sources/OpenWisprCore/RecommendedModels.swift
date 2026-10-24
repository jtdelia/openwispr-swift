private let whisperKitRepo = "argmaxinc/whisperkit-coreml"
private let whisperKitRevision = "0f63a7800b00dd0226abd051b906c246e1907482"
/// WhisperKit model folders ship without a tokenizer and fetch one at load time unless it sits beside them.
public let whisperTokenizer = ["tokenizer.json", "tokenizer_config.json"]

public let parakeetLanguages = [
    "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
    "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
]

/// Shipped with the app rather than fetched, so the network is only used for downloads the user starts.
public let recommendedModels: [ModelEntry] = [
    ModelEntry(
        id: "whisper-large-v3-turbo", name: "Whisper large-v3 turbo", task: .speechToText, engine: .whisperKit,
        sources: [
            ModelSource(repo: whisperKitRepo, revision: whisperKitRevision, folder: "openai_whisper-large-v3-v20240930_626MB"),
            ModelSource(repo: "openai/whisper-large-v3", revision: "06f233fe06e710322aca913c1bc4249a0d71fce1", files: whisperTokenizer),
        ],
        sizeBytes: 629_000_000, memoryBytes: 1_000_000_000, speed: .medium, languages: "99 languages", languageCodes: nil
    ),
    ModelEntry(
        id: "whisper-small", name: "Whisper small", task: .speechToText, engine: .whisperKit,
        sources: [
            ModelSource(repo: whisperKitRepo, revision: whisperKitRevision, folder: "openai_whisper-small_216MB"),
            ModelSource(repo: "openai/whisper-small", revision: "973afd24965f72e36ca33b3055d56a652f456b4d", files: whisperTokenizer),
        ],
        sizeBytes: 220_200_000, memoryBytes: 400_000_000, speed: .fast, languages: "99 languages, best in English", languageCodes: nil
    ),
    ModelEntry(
        id: "parakeet-tdt-0.6b-v3", name: "Parakeet TDT v3", task: .speechToText, engine: .fluidAudio,
        sources: [
            ModelSource(
                repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml", revision: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
                files: ["Preprocessor.mlmodelc/", "Encoder.mlmodelc/", "Decoder.mlmodelc/", "JointDecisionv3.mlmodelc/", "parakeet_vocab.json"]
            ),
        ],
        sizeBytes: 483_100_000, memoryBytes: 800_000_000, speed: .fastest, languages: "25 European languages", languageCodes: parakeetLanguages
    ),
    ModelEntry(
        id: "qwen3-4b-instruct-2507", name: "Qwen3 4B Instruct", task: .chat, engine: .mlx,
        sources: [ModelSource(repo: "mlx-community/Qwen3-4B-Instruct-2507-4bit", revision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b")],
        sizeBytes: 2_280_000_000, memoryBytes: 3_000_000_000, speed: .fast, languages: "119 languages", languageCodes: nil
    ),
    ModelEntry(
        id: "qwen3.5-9b", name: "Qwen3.5 9B", task: .chat, engine: .mlx,
        sources: [ModelSource(repo: "mlx-community/Qwen3.5-9B-MLX-4bit", revision: "938d8919941c6e7efd3c7150eff7fe9d12afa631")],
        sizeBytes: 5_980_000_000, memoryBytes: 7_500_000_000, speed: .medium, languages: "201 languages", languageCodes: nil,
        chatTemplateContext: ["enable_thinking": false]
    ),
    ModelEntry(
        id: "gemma-4-e4b", name: "Gemma 4 E4B", task: .chat, engine: .mlx,
        sources: [ModelSource(repo: "mlx-community/gemma-4-e4b-it-4bit", revision: "475b9088d29754a3379866cf5aeb6b41acd313c2")],
        sizeBytes: 5_180_000_000, memoryBytes: 6_500_000_000, speed: .medium, languages: "140+ languages", languageCodes: nil
    ),
    ModelEntry(
        id: "qwen3-vl-4b", name: "Qwen3-VL 4B Instruct", task: .vision, engine: .mlx,
        sources: [ModelSource(repo: "mlx-community/Qwen3-VL-4B-Instruct-4bit", revision: "2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b")],
        sizeBytes: 3_110_000_000, memoryBytes: 4_000_000_000, speed: .medium, languages: "Multilingual", languageCodes: nil
    ),
]
