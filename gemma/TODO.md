# GEMMA TODO

## Deferred fixes

- [ ] **Gemini safety-filter / empty-candidates diagnostics:** Investigate `[API Failure]: No candidates returned` on prompts that may be blocked by a safety filter. Inspect Gemini response metadata (including prompt-level block reasons and candidate finish reasons) and distinguish safety blocks from malformed request/context or other empty-response cases. Show a useful, specific diagnostic instead of the generic error; do not silently retry or alter the user's prompt.
- [ ] **Non-blocking TTS playback:** Audio playback must not block the readline/text input loop. While a cached or newly generated WAV is playing, the user must still be able to type and interact with GEMMA. Decouple playback from the input loop and define clean stop/replay behavior; keep compatibility with Windows PowerShell 5.1.
