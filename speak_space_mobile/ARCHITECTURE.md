# Speak Space iOS architecture

The app is a local-first native iOS application. “Frontend” and “Backend” describe responsibilities inside the app process; there is no remote server.

## App

`App/` owns application startup, dependency wiring, and the shared SwiftData container.

## Frontend

`Frontend/Views/` contains SwiftUI presentation and user interaction. Views call the backend services directly and persist user-visible state through SwiftData.

## Backend

- `Backend/Audio/` records audio and performs on-device speech transcription.
- `Backend/AI/` manages downloadable local models and generates summaries or to-do lists exclusively with llama.cpp.
- `Backend/Persistence/` defines the SwiftData entities, recording-file location strategy, and local persistence helpers.

## Resources and dependencies

- `Assets.xcassets/` contains app icons and visual assets.
- `Packages/LlamaRuntime/` wraps the llama.cpp XCFramework used for offline generation.

## Data flow

1. SwiftUI starts or stops a recording through `OnDevicePipeline`.
2. The pipeline stores the audio file and creates an on-device transcript.
3. The frontend saves the workspace, transcript, recording filename, and duration in SwiftData.
4. A note can request a summary or to-do list only when a downloaded local model is selected.
5. Playback resolves the stored filename against the app’s current sandbox at runtime.
