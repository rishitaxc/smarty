# Verification

The release is installed at `/Users/shritaake/Applications/Side.app`. Final verification is complete. Test speech was stopped, and the app was restarted quietly with the astronaut model, trees board and photo board restored.

## Automated and live checks

- The current local suite passes **24 checks, 0 failures** in `artifacts/local-final-checks.log`.
- The earlier combined run passed **29 checks, 0 failures**, including real Sol 2D requests, web research, TTS, and airplane, water molecule and motor geometry. See `artifacts/final-checks.log`.
- Five fresh space cases were generated through real agent calls: a NASA photo with a suit diagram, an orbit explanation, a spacewalk concept flow, a rocket cutaway and an astronaut suit. Their JSON, SVG and PNG artifacts are in `artifacts/space-cases/`.
- The initial fresh run caught two issues: Commons uses a separate thumbnail host, and the photo agent searched repeatedly rather than drawing. Both were fixed. The targeted photo/image run then passed **25 checks, 0 failures** in `artifacts/photo-retest.log`. Both real NASA and Commons downloads also pass in `artifacts/image-library-retest.log`. The original failed log is retained for an honest audit trail.

Local coverage includes geometry validation, SVG XML and escaping, signed arrow directions, Retina rendering, upright text through OCR, label fitting, constant-speed pencil traces, speech cue coverage, API payloads and credential redaction, silence handling, request cancellation, real 3D geometry, mesh validation, scene archive reload, incremental construction, bounded camera controls, undistorted wide labels, and credited photos embedded in offline SVG exports.

## Actual Mac observations

The 2D implementation was finished and exercised first. The supplied indexed tensor was rendered and inspected. A real spoken request was recorded by the laptop microphone, transcribed and sent to Sol, which drew the requested triangle. The conversation resumed listening after the spoken answer. Production microphone diagnostics record native voice processing enabled.

The triangle was traced during its corresponding sentence, with labels and equations added during subsequent cues. New final-release photo-board testing likewise showed the NASA photo before the hand-drawn suit systems. Timing evidence is in `artifacts/runtime-sync/timing.jsonl` and `artifacts/final-side-test/timing.jsonl`. Native pen input, Undo, resizing and Save SVG were exercised. Screen questions produced an annotation on the visible diagram.

The photo board contains a real NASA image with credit and source link, alongside editable vector drawings. The chosen image shows a suit being prepared inside the station; the board captions that accurately. It is not presented as an outdoor EVA photograph.

Live 3D construction now uses successive agent calls. In the running app, the astronaut suit was built in **five separate calls with 31 named parts**, starting with pressure layers and cooling tubes and ending with the life-support backpack. Each group appeared during its spoken explanation. The user could orbit during construction. See `artifacts/live-native-space/timing.jsonl`. The separate rocket used three construction calls and reached `complete=true`.

The native 3D controls were exercised: orbit, gentle centered zoom, reset, opaque exterior, cutaway, spread, rotation, label hiding/restoration, direct geometry selection, the complete parts menu, isolated Focus, close and reopen. Reopening from the notch preserves the model without replaying construction. Focus initially exposed an occlusion issue; it was fixed and retested with an isolated oxygen tank and a reset back to the whole suit. A wide-label distortion was also fixed and inspected on the water molecule.

Ask Side on the selected torso returned a spoken explanation with NASA sources and described the visible model. Parsed scene data before and after the follow-up remained identical. Export through the native Save dialog produced `artifacts/astronaut-native.scn`; SceneKit reloaded all **31 top-level parts with zero hidden parts**. Export builds a clean full model, so inspection state does not omit geometry.

The final voice controls entered Listening and returned cleanly to Ready with Escape. Test audio was stopped when requested. Final restoration uses no speech or automatic replay.

## Keychain, install and references

Only `OPENAI_API_KEY` was read from the authorized environment file. No password or production key is stored in source or artifacts. Side stores its own key entry under service `dev.side.notch.openai`. The final signed executable was restarted without any key-file or import argument; `artifacts/final-ready.log` reports `keyConnected: true`, `screenRecording: true`, `microphone: true` and `desktopAvailable: true`.

The final app passes `codesign --verify --deep --strict`. Source hygiene checks found no em dashes or embedded production credentials. The executable hash and detailed results are in `artifacts/verification.json`.

Both supplied PNGs and all seven videos were reviewed. Full-duration frame sampling, complete audio transcripts and reference notes are documented in `docs/REFERENCES.md` and `reference/`.

These are interactive educational models assembled from actual native geometry. The tested astronaut and rocket are simplified teaching assemblies.
