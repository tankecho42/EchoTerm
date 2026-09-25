# EchoTerm — English edition

46 seconds · 1920 × 1080 · 60 fps · H.264 / AAC

Film: `output/EchoTerm-Promo-English-46s.mp4`

English edition of v8. The five-second entrance, reading pauses, continuous three-window pixel flow, camera moves, themes and original instrumental score are preserved.

All visible copy is localized: headlines, the typed question and streaming answer, conversation status, session names, navigation details, theme names and appearance controls. Small labels inside the captured terminal plate are also localized, including the session rail and suggestion buttons. The pixel typography now forms **“block.”** as part of **“Every command. Its own block.”** English text uses the macOS system typeface with layouts checked for fit.

The optional English subtitle track uses the approved timeline. The soundtrack has no spoken narration.

## Production files

- `source/render-film.py` — film rendering and English typography.
- `source/localize-capture.py`, `assets/blocks-en.png` — localized labels in the existing terminal plate, preserving command output and layout.
- `source/translate-film.py` — reproducible copy and layout adaptation from v8.
- `source/timing.py` — unchanged v8 timing.
- `source/verify-film.py` — codec, frame count, full decode and encoded previews.
- `source/verify-english.py`, `source/language-check.json` — string checks and bilingual OCR of the localized plate and encoded scenes.
- `source/theme-flow-check.json` — continuity checks for the three-window animation.

This edition changes only promotional media. It does not localize or modify the installed EchoTerm app. Chinese v8 remains available. Product captures and composited explanatory animation follow the same approach as prior editions; the original AI demonstration used a scripted local provider.

Python runtime: `python3 (activated virtual environment)`. Dependencies: NumPy, OpenCV, Pillow, FFmpeg, AppKit and Vision. The English renderer writes text-cache images atomically to support parallel frame rendering.

## Validation

The final film is 46.000 seconds, 1920 × 1080, 60 fps and 2,760 frames. Full decode passed. All 190 rendered string literals and the SRT are free of CJK characters. Bilingual OCR of eight images, including the localized capture and encoded scenes, found no CJK text. English layouts and encoded key frames were visually checked. The continuous theme animation passed its 318-frame motion and join checks.
