# OpenWispr for macOS (Swift)

A native Swift port of [OpenWispr](https://github.com/jtdelia/openwispr), the open-source voice dictation
and meeting notetaker for macOS. Hold a key, speak in any app, and the cleaned-up text is pasted at your
cursor. It is a single SwiftUI app built on macOS 27, with no Electron and no helper processes.

## Features

Everything the Electron app does, with the same settings file, history and meetings:

- **Push-to-talk and hands-free dictation**: hold `fn` to talk, `fn + Space` to lock, `Esc` to cancel.
  All shortcuts can be rebound, and `⌃⌘V` / `⌃⌘C` paste or copy the last transcript.
- **Flow bar**: a Liquid Glass pill at the bottom of the screen with a live waveform. Click it to start
  hands-free.
- **AI cleanup** with per-app tone (personal, work, email, other), a **dictionary** of spellings and
  "replaces" rules, **snippets**, and **history and stats**.
- **Context-aware**: reads the text before your cursor through Accessibility and classifies the
  frontmost app.
- **Notetaker**: records your microphone and the call audio as separate channels, shows a live
  transcript, credits speakers that Google Meet, Zoom, Teams or Slack show talking, then titles the
  meeting and writes a Markdown summary with action items.
- **Models**: Apple's on-device speech-to-text and Foundation Models, downloaded MLX chat models and
  WhisperKit or Parakeet speech models, or any OpenAI-compatible endpoint.

### What macOS 27 brings

- Liquid Glass (`glassEffect`, `GlassEffectContainer`, glass button styles) for the Flow bar and hub.
- `SpeechTranscriber` and Foundation Models run in-process instead of in a separate model helper.
- Call audio comes from a Core Audio process tap (`CATapDescription`) rather than screen capture.
- Microphone capture uses the Sendable `installAudioTap` API, and device selection uses
  `withAUAudioUnit`.

## Install

Requirements: macOS 27, Xcode 27, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen swiftlint`).

```sh
git clone https://github.com/jtdelia/openwispr-swift.git
cd openwispr-swift
make run SIGNING_IDENTITY="Apple Development"
```

macOS ties Accessibility and Microphone grants to the signing identity. With an *Apple Development*
certificate (Xcode → Settings → Accounts) the grants survive rebuilds. Without one, `make run`
signs ad hoc and you grant access again after each build.

On first launch OpenWispr copies your settings, history, meetings and downloaded models from the
Electron app (`~/Library/Application Support/OpenWispr`) into
`~/Library/Application Support/OpenWispr-Swift`. Then, in **Settings**:

1. **Accessibility**: click *Grant access*, needed for shortcuts, pasting and app context.
2. **Microphone**: click *Allow*.
3. **Speech-to-text** and **Chat**: choose *Apple (on this Mac)*, a downloaded model, or an
   OpenAI-compatible endpoint. API keys are stored in the Keychain.

The Notetaker asks for *Screen & System Audio Recording* the first time it records call audio.

## Layout

```text
App/OpenWispr/          SwiftUI app: hub pages, Flow bar, audio capture, system integration
App/OpenWisprUITests/   XCUITest suite, run against fake engines with --ui-testing
Packages/OpenWisprCore/ Platform-free logic: dictation state machine, shortcuts, cleanup prompts,
                        meeting pipeline, stores, Models, providers (210 tests)
Packages/OpenWisprEngines/ On-device engines: Apple Speech, Foundation Models, MLX, WhisperKit,
                        Parakeet, plus the openwispr-smoke CLI
project.yml             XcodeGen project definition
```

## Development

| Command        | What it does                                         |
| -------------- | ---------------------------------------------------- |
| `make lint`    | SwiftLint in strict mode                             |
| `make test`    | OpenWisprCore unit tests (Swift Testing)             |
| `make build`   | Generate the Xcode project and build the app         |
| `make ui-test` | Run the XCUITest suite                               |
| `make run`     | Build, optionally sign, and open the app             |
| `make check`   | Lint, test and build                                 |

CI runs `make lint`, `make test`, and `make build` on a macOS 27 runner for every pull request. The CI
build is signed ad hoc and only checks that the app compiles; build and sign the app you run locally
with `make run`. `make ui-test` runs in CI only on manual dispatch: `gh workflow run ci.yml --ref <branch>`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security problems privately, as described
in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
