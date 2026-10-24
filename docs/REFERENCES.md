# Reference study

Both supplied PNG images were inspected at full size. All seven supplied video clips were decoded across their full duration into timestamped frames, and all seven audio tracks were transcribed in full. Contact sheets, selected full-size frames, metadata and transcripts are in `reference/`.

| File in Downloads | Duration | Observed behavior |
| --- | ---: | --- |
| WhatsApp Video 2026-10-24 at 02.11.27.mp4 | 13.68 s | A transparent 3D aircraft appears above the current browser, with force arrows and labels. |
| WhatsApp Video 2026-10-24 at 02.11.32.mp4 | 25.00 s | Longer aircraft demonstration, including changing orientation and labeled forces. |
| WhatsApp Video 2026-10-24 at 02.11.50 (1).mp4 | 8.28 s | Two paper-like boards present measured ingredients and cooking steps while the tutor speaks. |
| WhatsApp Video 2026-10-24 at 02.11.50.mp4 | 10.20 s | A dated visual timeline accompanies spoken historical information. |
| WhatsApp Video 2026-10-24 at 02.11.51.mp4 | 26.93 s | A question about the current calculus video opens a drawing board. An operation flow explains the chain rule for ln(3x² − 1), with highlights on the source content. |
| WhatsApp Video 2026-10-24 at 02.11.52 (1).mp4 | 10.08 s | A words-to-numbers-to-words diagram explains tensors and prediction, drawn progressively during speech. |
| WhatsApp Video 2026-10-24 at 02.11.52.mp4 | 7.36 s | A table of token IDs, growing contexts, arrows and next-token targets explains training examples. |

The PNGs show a 2 × 4 tensor board with values 18, 47, 56, 57 / 58, 1, 15, 47, zero-based row and column indices, a blue outline around x[1,2] = 15, a shape annotation, elementwise addition, and a yellow highlight on the source code behind the board.

The [HeyClicky changelog](https://www.heyclicky.com/changelog) was also inspected. Its October 23 entry confirms the relevant interaction pattern: a notch interface, voice with screen context, 2D drawing boards and annotations, and draggable 3D explanations. These references inform Side's interaction, without requiring the unrelated email, routine, billing or browser-agent features of that product.

The user's refinements set the implementation order: finish and verify 2D first, use real generated vector boards, synchronize pencil strokes to the explanation, make voice primary, retain screen awareness, then implement 3D.
