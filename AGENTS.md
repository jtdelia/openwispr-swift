# Agent instructions

Read this before changing anything in this repository.

## Project

A native Swift 6 port of [OpenWispr](https://github.com/jtdelia/openwispr), a voice dictation and
meeting notetaker for macOS 27. Platform-free logic (dictation state machine, shortcuts, prompts,
meeting pipeline, stores, `Models`) lives in `Packages/OpenWisprCore` and is unit tested with Swift
Testing. On-device engines (Apple Speech, Foundation Models, MLX, WhisperKit, Parakeet) live in
`Packages/OpenWisprEngines`. The SwiftUI app in `App/OpenWispr` wires them to macOS: `AppModel.swift`
is the composition root, `System/` holds Accessibility, the event tap and paste, `Audio/` holds capture,
and `Hub/`, `Settings/` and `FlowBar/` hold the UI. `OpenWispr.xcodeproj` is generated from `project.yml` by
XcodeGen and is not committed. Launching with `--ui-testing` swaps in fake engines and recorders
(`Testing/UITesting.swift`) for the XCUITest suite.

## Commands

- `make lint`: SwiftLint in strict mode
- `make test`: OpenWisprCore unit tests
- `make build`: generate the Xcode project and build the app
- `make ui-test`: the XCUITest suite
- `make check`: lint, test and build

Run `make lint` and `make test` before you say a change works.

## How to work

- **One task, one pull request.** Implement only what the issue asks. Leave anything listed
  under "Out of scope" alone, and do not refactor or reformat unrelated code.
- **Follow existing patterns.** Match the naming, structure, and style of nearby code
  before introducing anything new.
- **Test behavior changes.** Add or update tests for what you change.
- **Ask instead of guessing.** If a task is ambiguous, stop and explain what is missing
  rather than inventing requirements.
- **Never commit secrets,** credentials, or `.env` files.

## Pull requests

- The title is a conventional commit: `type(scope): summary`, where type is one of
  `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `ci`, `chore`, or `revert`.
- Fill in every section of `.github/pull_request_template.md`. Under Verification, list
  the commands you ran and what they showed. "Tests pass" alone is not enough.
- Link the issue with `Closes #<number>`.
