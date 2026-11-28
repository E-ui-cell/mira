# GEMMA TODO

## Deferred fixes

- [ ] **Restore long and multiline text input (major regression):**
  Progress: restored scrolling of the visible input rows when the logical prompt exceeds the console buffer, and restored Ctrl+V clipboard insertion with CR/LF normalization, NUL removal, and one-step undo. Interactive Windows PowerShell 5.1 validation is still required. The current input editor no longer reliably supports long prompts or multiline input/paste. Restore the full input-buffer behavior, including arbitrarily long practical input, multiple lines, multiline paste, cursor movement/editing across lines, and correct redraw without truncation, dropped text, or buffer corruption. Add regression tests for long single-line input, long multiline input, multiline paste, editing near the beginning/middle/end, and submission of the exact complete buffer. Validate interactively in Windows PowerShell 5.1; parser-only tests are not sufficient.
- [ ] **Input editor performance / typing lag:** Profile and optimize `Read-GemLineConsole` and its redraw path. Current implementation takes full-buffer undo snapshots on edits (up to 100) and recalculates layout plus clears/redraws the complete old/new screen region on each edit. Avoid repeated full-buffer/full-screen work for ordinary keystrokes; use incremental or dirty-region redraw where safe, and keep undo behavior correct. Test typing, cursor movement, paste and deletion in short and very long prompts; verify latency does not grow unacceptably with buffer length. Preserve Windows PowerShell 5.1 compatibility and Unicode/multiline correctness.
- [ ] **Startup latency:** Measure cold and warm startup, then identify and reduce PowerShell parsing/module-loading overhead. The launcher currently dot-sources 16 component scripts eagerly, while `ChatLoop.ps1` loads `Turn.ps1` when the chat loop is entered. Determine which components can be loaded lazily or consolidated without introducing first-use pauses, changing behavior, or breaking Windows PowerShell 5.1. Record before/after timings; do not optimize based only on assumptions.
- [ ] **API-key rotation edge-case consistency and regression tests:** Rotation exists for Gemini and OpenAI, but error classification differs between streaming and non-streaming paths. In particular, OpenAI non-streaming Responses API body failures returned with HTTP 200 use the central rotation-code list, while streaming also recognizes additional codes such as `rate_limit_error`. Reconcile the classifiers so equivalent API-level failures rotate consistently, while preserving the distinction between HTTP status and response-body status. Add mocked tests for invalid-key, quota/rate-limit, billing/account-limit, transient server/network errors, unrecognized errors, one-key pools, and multiple-key pools. Verify the selected key index advances correctly on success and failure; do not use live credentials in tests.
- [ ] **Gemini safety-filter / empty-candidates diagnostics:** Investigate `[API Failure]: No candidates returned` on prompts that may be blocked by a safety filter. Inspect Gemini response metadata (including prompt-level block reasons and candidate finish reasons) and distinguish safety blocks from malformed request/context or other empty-response cases. Show a useful, specific diagnostic instead of the generic error; do not silently retry or alter the user's prompt.
- [ ] **Non-blocking TTS playback and input:** Audio playback must not block the readline/text input loop. The user must be able to type and interact with GEMMA while audio is playing, including when audio is newly generated or loaded from cache. Decouple playback from the input loop and define clean stop/replay behavior; keep compatibility with Windows PowerShell 5.1.
- [ ] **TTS replay on Tab:** Prevent Tab completion/navigation from replaying the current audio when the input cursor is at the beginning of the line. Tab must perform only its intended editor/completion action in this state.
- [ ] **Gemini TTS server-error model rotation:** On retryable server-side TTS errors, rotate to the next configured TTS model and retry using configured Gemini API keys. Distinguish retryable server errors from non-retryable failures; do not repeatedly retry the same unavailable model. Preserve preferred-model ordering, key rotation, and bounded retry behavior. Record which model succeeds and include the model in the audio-cache key. Keep Windows PowerShell 5.1 compatibility.
- [ ] **TTS model compatibility:** Support all of these configured models: `gemini-3.8-flash-tts` (current preferred model), `gemini-3.1-flash-tts-preview`, `gemini-2.5-flash-preview-tts`, and `gemini-3.8-flash-lite-tts`. Implement model-specific request/response compatibility. In particular, Gemini 2.5 Flash TTS and Gemini 3.1 Flash TTS do not understand the newer audio tags and use a different format for director notes; support their format differences and the additional `scene` field instead of sending them the newer-model payload unchanged.
- [ ] **Manual TTS model selection:** Add a TTS model completion/picker opened by Ctrl+Tab when the input cursor is at the beginning of the line. Show the supported TTS model list and allow the user to manually switch the active TTS model. Ctrl+Tab elsewhere in the input must not unexpectedly open this picker or interfere with normal text editing.
- [x] **OpenAI API provider (initial Chat Completions implementation):** Added provider switching, model discovery/selection, configurable `OPENAI_API_KEY` / `OPENAI_API_KEYS`, conversation and image-message conversion, function/tool calls, usage reporting, bounded retries, and API-key rotation. Remaining provider-specific work: validate supported model parameters and add OpenAI-native reasoning controls if needed.

---

## Consolidated thin rewrite plan (moved from the former root `todo.txt`)

GEMMA — THIN REWRITE PLAN
=========================

Status: implementation authorized on branch thin. The rewrite is in progress.
The native GUI frontend remains a separate architecture decision; do not build
GUI code until the owner chooses the Win32 process/IPC architecture.

BASE
----
Repository: E-ui-cell/mira
Working branch: thin
Base branch: main
Base commit: latest main, merged into thin at 20c7e48 plus subsequent main fixes.
Current implementation reviewed: gemma/gemma.ps1 (about 2,639 lines / 139 KB,
41 PowerShell functions at initial planning time).

PRIMARY GOAL
------------
Replace the oversized, entangled gemma.ps1 with a small, reliable AI coding
agent for Windows. Keep the user-facing experience simple, fast, polished and
predictable. The core must remain maintainable and testable. The GUI should be
a first-class, native Windows application, not a web page inside a desktop
wrapper and not a heavy framework shell.

This is a rewrite plan, not a request to preserve every implementation detail.
Preserve useful user-visible capabilities and safety guarantees; remove
duplicate code, stale patches, dead paths, debug noise, accidental complexity
and features that do not justify their maintenance cost.

NON-NEGOTIABLE PRODUCT PRINCIPLES
---------------------------------
[ ] Small entry point and clearly separated responsibilities.
[ ] Exactly two supported answer providers:
    1. Google Antigravity OAuth provider.
    2. Gemini Developer API provider.
[ ] No silent provider switching, no hidden model substitution and no
    ungrounded fallback when Search is mandatory.
[ ] Model selection belongs to the user. Discover the provider's real model
    catalogue; do not invent display names or maintain a stale hand-written
    compatibility allowlist.
[ ] PowerShell-first local agent: generated and executed commands must be
    Windows PowerShell, not Bash.
[ ] Safe-by-default local execution. ASK is the default and Enter means Yes;
    AUTOPILOT is an explicit opt-in.
[ ] Keep the console frontend usable even if a GUI frontend is added.
[ ] No required third-party runtime, module, package manager, local service,
    browser engine or background daemon for the native GUI distribution.
[ ] No credentials, access tokens, private user data or API keys in source,
    logs, test fixtures or commits.
[ ] No diagnostic chatter in normal conversation output. Show actual errors,
    not internal implementation traces or successful tool-call announcements.

1. TWO PROVIDERS AND AUTHENTICATION
-----------------------------------
[ ] Define one provider interface and two independent provider adapters.

    A. ANTIGRAVITY OAUTH
       - Google Antigravity OAuth login using PKCE/state validation.
       - Store and refresh the user's token in the user's home directory.
       - Commands/actions for login, status and logout.
       - Discover available models from the account/API.
       - Send requests using the Antigravity request envelope and project data.
       - Keep request headers, token refresh and error parsing provider-local.
       - Never print tokens or OAuth payloads.

    B. GEMINI DEVELOPER API
       - Authenticate with the Gemini API key from the environment.
       - Discover models from the official model list and paginate correctly.
       - Use the Gemini generateContent request/response format.
       - Keep its generation config, safety settings, function calling and
         error handling separate from Antigravity's private API envelope.
       - Inspect the current GEMINI_APIJ variable spelling and decide the
         canonical environment variable. Preserve a migration alias if needed;
         do not silently break existing users.

[ ] Both providers must support model switching, request cancellation,
    conversation context, tool calls and useful usage/error information where
    the provider supplies it.
[ ] Provider-specific feature differences must be explicit, not hidden behind
    fragile shared conditionals.
[ ] Respect current user defaults during migration: Antigravity selected by
    default, current model/effort defaults, grounding enabled, Gemini API
    agentic web search enabled, ASK permission mode, verbose thought display
    disabled. Centralize and document defaults.
[ ] Keep provider and model state visible in both frontends.

2. GOOGLE SEARCH / GROUNDING
----------------------------
[ ] Preserve the two intentionally different Search paths.

    ANTIGRAVITY CHAT:
       - Native Google Search grounding using the selected Antigravity model.
       - Search-only preflight, then answer generation with grounded material.
       - Do not combine native googleSearch with local functionDeclarations if
         the endpoint rejects that combination.
       - Same selected model; no researcher subagent and no model fallback.
       - Require real grounding metadata before generating the answer.
       - If Search fails or metadata is missing, fail the turn. Never quietly
         continue as an ordinary ungrounded chat response.
       - Retry only transient failures with the identical request/model.
       - Retries remain silent; only a final failure is shown.

    GEMINI DEVELOPER API CHAT:
       - Keep the custom web_search function available only to this provider.
       - The PowerShell host executes the function using Antigravity OAuth and
         the dedicated Search model setting.
       - Return grounded sources/metadata to the Gemini API model as tool data.
       - Do not expose this custom research function to Antigravity models.

[ ] Keep .grounding on/off/status and a clear master switch.
[ ] Keep source titles, source URLs, dates and grounding metadata attached to
    the correct answer. Do not fabricate or silently rewrite source URLs.
[ ] Clearly distinguish Search errors from answer-generation errors.

3. AI CODING AGENT / TOOL ENGINE
--------------------------------
[ ] Implement one explicit agent loop:
       user input -> context -> model request -> tool calls -> tool results ->
       next model request -> final answer.
[ ] Support bounded multi-step tool execution and prevent infinite loops.
[ ] Track a turn as one unit. On cancellation or request failure, roll back
    partial user/model/tool messages so the next turn starts with valid context.
[ ] Keep tool schemas, dispatch, validation, permission checks and result
    serialization in one consistent registry rather than scattered switches.
[ ] Local tools currently present and to preserve/review:
       - run_powershell: execute PowerShell on the user's Windows machine.
       - get_current_datetime: return actual local date/time and timezone.
       - quick_web: narrow weather, public-IP and cheat-sheet lookups.
       - get_skill: discover and load a built-in or user skill.
       - web_search: Gemini Developer API provider only, when enabled.
[ ] Keep the ability to use tool results in follow-up steps. The model must not
    claim that a command ran, a file changed or a task completed unless the
    host tool actually reports success.
[ ] Retain command-generation mode:
       gemma -e "..."
    It returns a ready-to-run PowerShell command and does NOT execute it.
[ ] Retain one-shot prompt mode:
       gemma -p "..."
    Keep interactive mode as the normal launch experience.
[ ] Add clear boundaries between model-generated commands, tool execution,
    local direct actions and ordinary answer text.

4. POWERSHELL EXECUTION AND WINDOWS INTEGRATION
-----------------------------------------------
[ ] ASK permission mode is the default. Display the exact command/action and
    default the confirmation prompt to Yes (Enter = Yes).
[ ] AUTOPILOT is an explicit opt-in that allows model-requested PowerShell
    commands without per-command confirmation. Make the current mode obvious.
[ ] Keep confirmation for sensitive direct actions even when the UI changes.
[ ] Preserve/review native Windows capabilities currently exposed through the
    direct-command helper:
       - system information and process listing
       - clipboard read/write (only when specifically requested)
       - window listing and activation
       - UI Automation tree inspection and UI actions
       - application launch
       - Windows Settings page launch
       - network checks
       - file search
[ ] Preserve the built-in task skills and user skills under the user's
    .gemma\skills directory. Skill text is untrusted input, never a permission.
[ ] Do not poll or read the clipboard automatically. Keep secrets out of
    history, telemetry and diagnostic output.
[ ] Inspect before modifying files/settings; never silently elevate privileges.

5. FILES, IMAGES, SCREENSHOTS AND DIFFS
--------------------------------------
[ ] .text <path> sends UTF-8 text content.
[ ] .file <path> attaches supported binary/multimodal content; retain or
    deliberately revise support for PNG, JPEG, WEBP, PDF, MP3, WAV, MP4, CSV,
    HTML and JSON.
[ ] File picker when no path is provided; handle cancellation cleanly.
[ ] .shot captures an explicitly requested clipboard screenshot and sends it
    as an image. Never read clipboard images on startup or in the background.
[ ] .diff <left> <right> sends a useful comparison of two files with optional
    user instructions.
[ ] Enforce configurable size limits and clear errors for unsupported types.
[ ] Preserve paths containing spaces and Unicode paths.

6. CONVERSATION, HISTORY AND OUTPUT
-----------------------------------
[ ] Keep conversation context in memory during the active interactive session.
[ ] .clear clears the current conversation.
[ ] .exportsession [name] exports context to JSON; .loadsession <name> restores it.
[ ] Review session serialization for versioning, validation and safe handling
    of malformed/untrusted session files.
[ ] Keep a bounded local input history and keyboard navigation. Do not persist
    private conversation content unless the user explicitly exports it.
[ ] .save extracts fenced code blocks from the latest model response.
[ ] Preserve response time, selected model and provider-supplied token counts.
[ ] Preserve optional thought-summary display behind .verbose; never expose
    hidden reasoning or internal debug traces.
[ ] Keep errors concise and actionable. No successful tool-call banners,
    retry countdown messages, payload dumps or implementation diagnostics.

7. CLI / CONSOLE FRONTEND
-------------------------
[ ] Keep a small PowerShell launcher/CLI for users who prefer the terminal.
[ ] Restore reliable long and multiline text input (major regression):
    the current editor no longer supports long prompts and multiline input
    reliably. Restore long single-line buffers, multiple lines, multiline
    paste, editing/cursor movement across lines, and exact full-buffer
    submission. Prevent truncation, dropped pasted text, redraw corruption
    and accidental submission. Add regression tests for long single-line and
    multiline prompts, multiline paste, edits at the beginning/middle/end,
    and exact submitted content. Validate interactively in Windows PowerShell
    5.1; parser-only/module tests are not sufficient.
[ ] Input editor performance: profile and optimize the custom editor's edit
    path. Current behavior stores full-buffer undo snapshots (up to 100) and
    recalculates layout, clears the previous/new screen region, and redraws the
    complete buffer on each edit. Avoid full-buffer/full-screen work for every
    keystroke where possible; use incremental/dirty-region redraw while keeping
    undo correct. Benchmark short and very long prompts, typing, cursor moves,
    paste and deletion. Latency must not grow unacceptably with buffer length.
    Preserve Unicode, multiline behavior and Windows PowerShell 5.1 support.
[ ] Startup latency: measure cold and warm startup and profile PowerShell
    parsing/module-loading costs. The launcher currently dot-sources 16
    component scripts eagerly; ChatLoop loads Turn.ps1 when the chat loop is
    entered. Evaluate safe lazy loading or consolidation without introducing
    first-use stalls, changing behavior, or breaking Windows PowerShell 5.1.
    Record before/after timings; do not treat the suspected overhead as a
    measured result until timings confirm it.
[ ] API-key rotation consistency and tests: rotation is implemented for
    Gemini and OpenAI, but streaming and non-streaming error classification
    is not fully consistent. OpenAI non-streaming Responses API body failures
    returned with HTTP 200 use the central rotation-code list; streaming also
    recognizes additional codes such as rate_limit_error. Reconcile handling
    so equivalent API-level failures rotate consistently, while keeping HTTP
    status separate from response-body status (completed/failed/incomplete).
    Add mocked tests for invalid keys, quota/rate-limit and billing/account
    limits, transient HTTP/network failures, unrecognized errors, single-key
    pools and multi-key pools. Verify index advancement on success/failure;
    never use live credentials in tests.

[ ] Preserve useful command completion, path completion, model completion,
    history navigation and common editing shortcuts.
[x] Implement Bash Readline / Emacs editing keys in the custom input editor:
       - Ctrl+A / Ctrl+E: beginning / end of the current line.
       - Ctrl+B / Ctrl+F: move backward / forward one character.
       - Alt+B / Alt+F: move backward / forward one word.
       - Ctrl+P / Ctrl+N: previous / next input-history entry.
       - Ctrl+H / Backspace: delete character before cursor.
       - Ctrl+D / Delete: delete character at cursor; EOF on an empty buffer.
       - Ctrl+K: kill from cursor to end of current line.
       - Ctrl+U: kill from beginning of current line to cursor.
       - Ctrl+W: kill the previous word.
       - Alt+D: kill the next word.
       - Ctrl+Y: yank the most recently killed text.
       - Ctrl+T: transpose adjacent characters.
       - Alt+T: transpose adjacent words.
       - Ctrl+L: clear and repaint the console without losing the edit buffer.
       - Ctrl+R / Ctrl+S: search the current buffer text in history and cycle
         backward / forward through substring matches.
       - Ctrl+G: cancel an active history-search selection.
       - Alt+Backspace: kill the previous word.
       - Ctrl+Z / Ctrl+_: undo the last edit.
       - Ctrl+V / Ctrl+Q: insert the next key literally.
       - Alt+C / Alt+U / Alt+L: capitalize / uppercase / lowercase the word.
       - Alt+Y: cycle recent kill-ring entries after yanking.
       - Alt+< / Alt+>: jump to oldest / newest history entry.
    Implemented in gemma/ui/LineEditor.ps1. CI parser and helper tests cover
    module loading and word/history operations; terminal interaction still
    needs manual validation in Windows PowerShell 5.1.
[x] Ctrl+J inserts a newline in the current prompt buffer. It never submits
    the request. Enter submits the complete multiline prompt.
    Implemented in Read-GemLineConsole; Windows PowerShell 5.1 CI covers module load.
[ ] Preserve Unicode insertion, multi-line paste, cursor movement across lines,
    redraw after resize, and history navigation without corrupting the buffer.
[ ] Avoid conflicting bindings: when editing a multiline buffer, Up/Down move
    between visual/logical lines where possible; use Ctrl+P/Ctrl+N for command
    history. Document any unavoidable terminal-host limitations.
[x] Rebuild the model picker as an interactive, scrollable list:
       - Up / Down and j / k move the highlighted model.
       - Home / End jump to first / last; PageUp / PageDown scroll a page.
       - Enter selects the highlighted model; Esc or q cancels unchanged.
       - Current model is visibly marked and initially highlighted.
       - Long model IDs remain readable; the list scrolls within terminal size.
       - Model IDs and provider metadata come from the live provider catalogue;
         display labels must not be fabricated.
       - Preserve direct .model <exact-id> selection without opening the menu.
       - Keep menu feedback concise; no debug/status dumps while navigating.
    Implemented on thin in gemma/gemma.ps1 by Read-GemmaModelSelection.
    Interactive key handling is implemented; clean-host visual testing remains.
[ ] Commands currently exposed and to review for parity:
       .q / quit
       .clear
       .model [model]
       .provider [antigravity|gemini]
       .effort [low|medium|high]
       .auth [login|status|logout]
       .grounding [on|off|status]
       .ask
       .autopilot
       .verbose [on|off]
       .file <path>
       .text <path>
       .shot [prompt]
       .diff <left> <right> [prompt]
       .save
       .exportsession [name]
       .loadsession <name>
       .skills
       .skill <name>
       !<PowerShell command>
       -p <prompt>
       -e <command request>
[ ] Ensure the help text is generated from the actual command registry so it
    cannot drift from the implementation.
[ ] Preserve a clean spinner/progress indicator and Ctrl+C cancellation.
    The spinner is progress feedback; API retry internals remain hidden.
[ ] Investigate intermittent Ctrl+C behavior where GEMMA exits instead of
    cancelling only the active operation; identify the triggering contexts.
[ ] Make LLM-launched commands independently cancellable. Retain the child
    process handle and support terminating the launched process/tree (including
    applications started by a command) without exiting the GEMMA session.

8. NATIVE WINDOWS GUI — DESIGN DISCUSSION BEFORE IMPLEMENTATION
---------------------------------------------------------------
User wants a small, lightning-fast, good-looking, native Win32 GUI shell with
no external runtime dependencies. This is a core product direction, but the
frontend/backend boundary must be agreed before code is written.

Preferred candidate to evaluate:
    A small C++ Win32 desktop executable using the Windows API directly.
    Use system-provided Windows libraries/controls only; no Electron, browser,
    WebView2, WinUI 3 runtime, Qt, GTK, Python, Node, Java or external UI
    framework. Build-time compiler/toolchain is not a user runtime dependency.

Potential implementation:
    - Native window/message loop and normal Windows process lifecycle.
    - Custom-drawn chat surface using GDI or system Direct2D/DirectWrite for
      polished text layout, DPI awareness, smooth scrolling and custom chrome.
    - System Rich Edit control (Msftedit.dll) or a custom editor for robust
      Unicode, multiline input, selection, clipboard and paste.
    - Native menus, keyboard accelerators, file dialogs and notifications.
    - Dark/light theme, compact header, chat transcript, composer, send/stop,
      attachment controls and a clear provider/model/grounding status area.
    - Responsive resize, high-DPI display support, keyboard-first navigation,
      accessible controls and minimal CPU/memory usage.
    - No network calls or credentials in the UI layer; the agent core owns them.

FRONTEND / BACKEND OPTIONS TO DISCUSS:
    A. Native C++ GUI shell + persistent PowerShell 5.1 agent process.
       - GUI starts a hidden PowerShell child once and keeps it alive.
       - Communicate through a versioned JSON-lines protocol over redirected
         stdin/stdout (or a named pipe if there is a strong reason).
       - Backend emits structured events: response chunks, status, tool
         approval request, tool result, error, model list and completion.
       - GUI sends structured user actions; PowerShell owns API, OAuth,
         tool execution, permissions and session state.
       - Avoid PowerShell console text in the protocol. stdout is protocol-only;
         stderr is for actionable diagnostics.
       - This is the lowest-risk way to keep current PowerShell integrations
         while making the visible app truly native and responsive.

    B. Entire application in native C++.
       - GUI, HTTP transport, OAuth, providers, agent loop, tool schemas,
         permissions and session state all move into the native executable.
       - Use Windows HTTP/crypto/process APIs and a small internal JSON parser.
       - Offers a single native application and removes PowerShell startup/
         hosting from the runtime path, but is a much larger security-sensitive
         rewrite. Only choose after estimating scope and testing OAuth parity.

    C. .NET Framework WinForms/WPF front end.
       - Faster to prototype and compatible with the Windows PowerShell/.NET
         Framework ecosystem, but not the preferred answer to the user's
         strict native/no-dependency/very-fast GUI requirement.
       - Keep only as a fallback if native C++ costs outweigh its advantages.

RECOMMENDATION FOR CONSULTATION:
    Start by evaluating option A: a native Win32 C++ shell and a persistent,
    headless PowerShell agent backend with a small, versioned IPC contract.
    It separates UI from agent behavior, allows the PowerShell core to remain
    compact/modular, and avoids reimplementing OAuth and PowerShell safety in
    C++ immediately. Keep option B open if absolute single-process/native
    execution proves more important than retaining PowerShell integrations.

UI CONCEPT:
    - Header: Gemma identity, provider, model, grounding and permission state.
    - Main: scrollable conversation with readable typography and code blocks.
    - Composer: multiline editor, paste support, Enter-to-send and configurable
      newline shortcut.
    - Actions: send, stop/cancel, attach file, attach screenshot, copy response.
    - Model/provider picker, effort selector, auth status and grounding toggle.
    - Tool approval sheet/dialog showing the exact command with Yes/No and
      Enter=Yes; obvious ASK/AUTOPILOT state.
    - No debug console. Optional concise activity/status area for actual work.
    - Preserve a lightweight terminal mode; GUI is not a mandatory dependency.

DECISIONS NEEDED BEFORE GUI CODING:
    [ ] Confirm whether Windows 10/11 only or Windows 7 compatibility is still
        required for Gemma.
    [ ] Choose A (Win32 shell + PowerShell backend) or B (all native C++).
    [ ] Decide whether the GUI is the default launch or an explicit gemma-gui
        executable while gemma.ps1 remains the CLI.
    [ ] Agree on visual direction, keyboard shortcuts and dark/light defaults.
    [ ] Decide whether chat content is stored only in RAM unless exported.
    [ ] Confirm whether any current command should be removed rather than kept.

9. REWRITE / REFACTOR SEQUENCE
------------------------------
[ ] Phase 0 — Architecture approval.
    Review this inventory, clarify the native GUI boundary, confirm OS support
    and approve the feature-parity list. Do not start implementation before GO.

[ ] Phase 1 — Freeze behavior and safety contracts.
    Write focused tests and fixtures for both provider request envelopes,
    token refresh, model discovery, Search metadata, tool calls, command mode,
    permissions, cancellation and context rollback. No live credentials in CI.

[ ] Phase 2 — Design the small core.
    Separate configuration, provider adapters, auth, transport, agent loop,
    tool registry, permission policy, session state and frontends. Remove
    duplicated provider/request logic without erasing provider differences.
    Keep gemma.ps1 as a small launcher if that remains the agreed interface.

[ ] Phase 3 — Implement provider and agent core.
    Rebuild the two providers, model list, auth, generation settings, tool
    loop, mandatory grounding rules, PowerShell execution and error handling.
    Test with mocked responses first; then perform live manual checks per
    provider using the owner's own OAuth/API credentials.

[ ] Phase 4 — Restore CLI parity.
    Implement interactive input, completion, paste, commands, sessions,
    attachments and terminal progress. Keep normal console output clean.

[ ] Phase 5 — Native GUI prototype.
    Build a tiny Win32 proof-of-concept: window, DPI, transcript, composer,
    multiline paste, scrolling, send/stop and process shutdown. No provider
    code until the native shell and IPC protocol are stable.

[ ] Phase 6 — Connect GUI to agent.
    Add persistent backend process, protocol versioning, structured events,
    streamed output, tool approval prompts, cancellation and error display.
    Ensure that UI responsiveness never blocks network/tool execution.

[ ] Phase 7 — Validation and release.
    Test Windows PowerShell 5.1 parsing, both providers, Search-grounding
    success/failure, no-fallback behavior, tool safety, multiline input,
    Unicode, paths with spaces, cancellation, session files, GUI DPI/resizing,
    process exit and dependency-free clean-machine startup. Keep CI green.

10. ACCEPTANCE CRITERIA
-----------------------
[ ] The launcher is genuinely small; implementation is divided by responsibility.
[ ] Exactly two provider adapters work independently and can be switched explicitly.
[ ] OAuth and API-key authentication work without exposing secrets.
[ ] Grounding is real, source-backed and strict; no ungrounded fallback.
[ ] The agent can inspect and modify the local Windows environment through
    PowerShell tools, subject to ASK/AUTOPILOT permissions.
[ ] -e generates a command but never executes it.
[ ] Existing approved features are preserved or explicitly removed by agreement.
[ ] GUI is a native Windows executable, starts quickly, remains responsive and
    has no external runtime/library requirement for end users.
[ ] CLI remains useful and the same agent core powers both frontends.
[ ] No debug chatter; meaningful errors are retained.
[ ] PowerShell 5.1 and the agreed Windows versions pass automated/manual tests.

IMPLEMENTATION PROGRESS (BRANCH thin)
---------------------------------------
- thin started from the latest main baseline and retains this plan. All rewrite
  source changes remain isolated to thin; main has not been modified by the
  rewrite work.
- Rebuilt the provider model picker as a scrollable interactive list:
  Up/Down and j/k navigation, Home/End, PageUp/PageDown, Enter, Esc and q.
  Direct .model <exact-id> selection and redirected-input fallback remain.
- Rebuilt the custom console editor and implemented Ctrl+J newline insertion
  with Enter submitting the complete multiline prompt.
- Implemented Bash/Emacs Readline shortcuts in gemma/ui/LineEditor.ps1:
  Ctrl+A/E/B/F, Alt+B/F, Ctrl+P/N, Ctrl+R/S incremental history search,
  Ctrl+G/Esc cancellation, Ctrl+H, Ctrl+D, Ctrl+K/U/W, Alt+D/Backspace,
  Ctrl+Y/Alt+Y kill-ring operations, Ctrl+T/Alt+T transpose, Ctrl+L,
  Ctrl+Z/Ctrl+_, Ctrl+V/Ctrl+Q quoted insert, Alt+C/U/L word case, and
  Alt+< / Alt+> history endpoints. Manual key-by-key console testing remains.
- Split first-party components (no third-party runtime/modules added):
      gemma/config/Cli.ps1                 argument and -p/-e mode initialization
      gemma/config/Defaults.ps1            runtime defaults and request settings
      gemma/providers/GeminiApi.ps1        Gemini Developer API provider
      gemma/providers/Antigravity.ps1      Antigravity OAuth and grounding
      gemma/agent/Execution.ps1            permission gate and PowerShell tools
      gemma/agent/Skills.ps1               built-in and user skills
      gemma/agent/Settings.ps1             provider/effort commands
      gemma/agent/Conversation.ps1         payload and conversation helpers
      gemma/agent/ChatLoop.ps1             interactive command/input loop
      gemma/agent/Turn.ps1                 per-turn agent/tool/request cycle
      gemma/windows/Native.ps1             Win32 clipboard/window/UIA actions
      gemma/ui/ModelPicker.ps1             interactive model picker
      gemma/ui/LineEditor.ps1              custom Readline editor
      gemma/ui/Output.ps1                  response normalization/code saving
- gemma/gemma.ps1 is now about 39 lines: a small bootstrap that loads the
  configuration, providers, agent components, UI and native Windows layer.
  The extracted ChatLoop and Turn modules contain the remaining orchestration;
  deeper cleanup and architecture tests are still required.
- Fixed CLI initialization during extraction and added regression coverage for
  -p, -e and Explorer's legacy Run with PowerShell argument wrapper.
- Standardized Gemini API key lookup on GEMINI_API while preserving
  GEMINI_API_KEY and historic GEMINI_APIJ aliases; added precedence tests.
- Added deterministic tests for Search intent so ordinary text ("test", "ok",
  "what?", "ll") does not invoke Search, while current news/search requests do.
- CI parses every Gemma component directory with Windows PowerShell 5.1 and
  tests module loading plus CLI, key-alias, Search-intent and Readline helpers.
- Parser/component tests do not prove live OAuth/Search or console key behavior.
  Live requests, grounding metadata, actual terminal input/paste, cursor redraw
  after resize and model-menu interaction still need manual Windows testing.
- Native Win32 GUI remains a design decision only. No GUI code or external
  UI dependencies have been added. The owner must choose GUI/backend architecture
  before GUI implementation begins.
- This is an incremental rewrite, not a completed rewrite or release-ready build.

- Planned, not implemented: TTS-only model/key rotation across the
  configured Gemini API keys and supported TTS models. Current preferred model:
  gemini-3.8-flash-tts. Also support gemini-3.1-flash-tts-preview,
  gemini-2.5-flash-preview-tts and gemini-3.8-flash-lite-tts. On retryable
  server-side TTS errors, rotate to another eligible model/key combination;
  track per-combination quota/rate-limit state, use bounded retries, and cycle
  back when cooldowns expire. Regular text-model provider rotation is out of
  scope.
- Planned, not implemented: Add model-specific TTS payload compatibility.
  Gemini 2.5 Flash TTS and Gemini 3.1 Flash TTS do not support the newer audio
  tags and use a different director-notes format; handle those differences and
  their additional scene field instead of sending the newer-model payload
  unchanged.
- Planned, not implemented: Add manual TTS model switching through a picker
  opened by Ctrl+Tab only when the input cursor is at the beginning of the
  line. Show the supported TTS models and let the user select the active model.
- Planned, not implemented: Fix Tab behavior so pressing Tab at the beginning
  of the input line does not replay the current audio.
- Planned, not implemented: Keep text input responsive while audio playback is
  active, including playback of cached audio. Playback must not block the
  readline/input loop; preserve clean stop/replay behavior and PowerShell 5.1
  compatibility.

CURRENT INVENTORY NOTES
-----------------------
The reviewed script currently contains 41 functions and about 2,639 lines.
Important implementation areas include: OAuth/PKCE and refresh; two provider
request formats; two different Search paths; dynamic model discovery; tool
calling and the agent loop; PowerShell execution policy; built-in/user skills;
native Windows interop; readline/history/completion; attachments and diffs;
JSON session export/import; code-block saving; cancellation, spinner and token
accounting.

The current script is the behavior reference, not a design template. Its
structure, naming, patches and implementation choices are not requirements.
The separate root-level MIRA project/script is not part of this Gemma rewrite
unless the owner later asks to merge or share code.

SCOPE CONTROL
-------------
AUTHORIZED SCOPE ON BRANCH thin:
    - Rewrite/refactor Gemma on thin only. Never make rewrite commits on main.
    - Keep main stable; do not merge thin into main until the owner asks.
    - Add tests as behavior is rewritten; keep Windows PowerShell 5.1 support
      unless the owner explicitly changes the platform target.
    - Native GUI source remains blocked pending the separate Win32 architecture
      decision. Planning and discussion are allowed; no GUI implementation yet.
    - Keep todo.txt current as implementation decisions and features land.
