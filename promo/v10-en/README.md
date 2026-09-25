# EchoTerm — English edition, refined pixel type

46 seconds · 1920 × 1080 · 60 fps

Film: `output/EchoTerm-Promo-English-v10-46s.mp4`

This revision refines the pixel word **block.** in the second scene. The letters are now drawn on a dedicated nine-row bitmap grid, with one-cell strokes, a common lowercase height and baseline, deliberate spacing, and separate punctuation. The previous font-threshold sampling could merge neighboring pixels and produce inconsistent stroke weights.

Every square uses the same 5.2-pixel size on a 6-pixel grid. The completed word contains 82 unique cells. Excess arrival particles disappear before settling; only one particle draws each cell when departure begins. Trail particles and square rotation ease in after departure, preventing a weight or edge change at the transition.

The reading hold, film duration, English copy, other scenes, theme animation and original score are preserved. The previous English edition remains in `../v9-en`.

## Files

- `source/pixel_type.py` — custom lowercase letter grids and optical layout.
- `source/render-film.py` — revised particle endpoints, sizing and compositing.
- `source/check-pixel-type.py`, `pixel-type-check.json` — grid and transition validation.
- `source/verify-film.py`, `media-check.json` — final media validation and encoded frames.
- `source/verify-english.py`, `language-check.json` — English copy and OCR checks.
- `previews/pixel-word-detail.png` — enlarged pixel lettering.

Pixel-type checks confirm no duplicate cells and identical raw RGB rendering at both the arrival and departure joins. This change affects promotional media only, not the installed application.

Python runtime: `python3 (activated virtual environment)`. Dependencies and existing capture/compositing methods are unchanged from the previous edition.

## Final validation

The encoded film is 46.000 seconds, 1920 × 1080, 60 fps and 2,760 frames. Full decode passed. The encoded lettering frame was visually checked. English checks passed for 188 rendered string literals, the subtitle file, and bilingual OCR of eight captured/encoded images. Both pixel-word transition endpoints match the completed glyph exactly before encoding.
