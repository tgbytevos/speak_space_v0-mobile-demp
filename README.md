# Speak Space Mobile

A local-first iPhone voice workspace. Record a voice note, transcribe it on device, edit and replay the transcript, then generate a summary or to-do list without sending workspace data to a server.

## Project structure

```text
.
├── speak_space_mobile/
│   ├── App/                     # App entry point and dependency wiring
│   ├── Frontend/Views/          # SwiftUI screens and components
│   ├── Backend/
│   │   ├── Audio/               # Recording, Whisper downloads, local transcription
│   │   ├── AI/                  # llama.cpp generation and local model downloads
│   │   └── Persistence/         # SwiftData entities and recording storage
│   ├── Assets.xcassets/         # App resources
│   └── ARCHITECTURE.md          # Responsibilities and data flow
└── Packages/
    ├── LlamaRuntime/            # llama.cpp binary Swift package
    └── WhisperRuntime/          # whisper.cpp binary Swift package
```

## Requirements

- Xcode 17 with the iOS 26.5 SDK
- An iPhone running iOS 26.5 for recording and on-device transcription
- A personal Apple Development team for running on a physical device

## Run

1. Open `speak_space_mobile.xcodeproj` in Xcode.
2. Select the `speak_space_mobile` scheme.
3. Choose your development team and, if necessary, a unique bundle identifier.
4. Select an iPhone and press Run.
5. Allow microphone and speech-recognition access on first use.

Workspace data, recordings, transcripts, and downloaded models remain inside the app sandbox. Rebuilding normally preserves them; deleting the app removes them.
