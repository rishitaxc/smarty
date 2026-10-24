# Side

A native macOS voice companion in the notch. Ask Sol a question, explain what you see, or request a drawing. Side opens vector sketch boards and draws each part while speaking about it.

Requires macOS 14 or later, the Swift command-line tools, and an OpenAI API key. No Node server or web application is required.

## Build and run

```sh
zsh scripts/build.sh
open ~/Applications/Side.app
```

Use Side Settings to save an OpenAI key in Mac Keychain. For an authorized local environment file, the app can import only `OPENAI_API_KEY`:

```sh
~/Applications/Side.app/Contents/MacOS/Side --import-key-from /absolute/path/to/.dev.vars
```

Quit an existing instance before using startup flags. A second instance activates the first instance instead of starting a second microphone or duplicate hotkeys.

## Use

- Click the notch or press Shift+Command+D to open Side.
- Click **Talk to Side** or press Shift+Command+Space to start a voice conversation. Pause to send a question, or tap the voice action again to finish speaking.
- Side captures the current display when you submit a question with **Screen on**. Follow-up screen captures happen only during that request when Sol calls its observation tool.
- Side speaks and draws in coordinated teaching beats. For example, the triangle is traced during “Imagine a triangle,” followed by the labels and equation as those are explained.
- A voice conversation returns to listening after the reply. Use **End voice conversation** or Escape to stop.
- The keyboard icon opens optional text input. Spoken replies and screen sharing have separate controls.
- Drawing boards can be moved and resized. The pencil adds your own strokes, Undo reverses the last change, and **Save SVG** exports vectors and text.
- Ask for images to retrieve real NASA or Wikimedia Commons photos. Side places credited photos beside the vector explanation; SVG exports embed the photo so they work offline.
- Ask for a 3D model to open the workspace on the left. The agent adds successive groups of real parts while explaining them. Drag to orbit during construction, scroll to zoom, and click a part to inspect it. **Inside** fades the outer shell, **Spread** separates components, and **Focus** frames the selected part.
- Use the notch’s **Show 3D model** button to reopen a model. **Ask Side** explains a selected part while preserving its geometry. Construction replay is an explicit control in the model window. Rotation, labels, reset and native scene export are also available.

Example questions:

```text
Explain the math on my screen and draw it step by step.
Imagine a right triangle. Draw it, label the sides, and explain Pythagoras.
Show me a 2 by 4 tensor and explain x[1,2].
Look up how Webb's sunshield works and draw a diagram with the source.
Show me a 3D airplane and explain lift, weight, thrust and drag.
Build a 3D water molecule and explain its bent shape.
```

The default reasoning model is `gpt-6.1-sol`; Settings also offers GPT-6 Sol. Speech recognition uses `gpt-transcribe`, and spoken output uses `gpt-4o-mini-tts`, with a Mac voice fallback. The implementation follows the official documentation for [Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol), [function calling](https://developers.openai.com/api/docs/guides/function-calling), and [web search](https://developers.openai.com/api/docs/guides/tools-web-search).

## Checks

```sh
swift run SideChecks
```

The checks cover drawing geometry, all seven vector primitives, invalid payloads, SVG XML and escaping, Retina rendering, text orientation through OCR, fitting labels, arc-length pencil animation, speech cue order, API payloads, web controls, credential redaction, and silence handling. They use a standalone executable so a full Xcode installation and XCTest are not required.

To run real Sol, research and TTS checks with the authorized key held only in the test process:

```sh
swift run SideChecks --live --key-file /absolute/path/to/.dev.vars
swift run SideChecks --live-3d --key-file /absolute/path/to/.dev.vars
swift run SideChecks --space-cases --key-file /absolute/path/to/.dev.vars
```

Live results are written under `artifacts/live-2d/` and `artifacts/live-3d/`. The 3D checks verify actual geometry, signed arrow directions, mesh validation and scene export. Development-only startup flags support saving QA drawings and timing traces, replaying a saved scene, and a physical speaker-to-microphone conversation check. The normal app keeps the session in memory and does not save screenshots or recordings. Public reference photos and their source credits are cached in the Mac Caches directory. Microphone recordings used for transcription are deleted after each request. Mac voice processing provides echo cancellation and noise suppression during a conversation.

The source clips and exact observations are documented in [docs/REFERENCES.md](docs/REFERENCES.md).

Image retrieval follows the official [NASA Image and Video Library API](https://images.nasa.gov/docs/images.nasa.gov_api_docs.pdf) and [MediaWiki Imageinfo API](https://www.mediawiki.org/wiki/API:Imageinfo).
