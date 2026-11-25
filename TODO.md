# Gemma Native — C++ / Win32 Rewrite Plan

**Status:** Future project — planning only. No implementation is authorized by this TODO.
**Branch:** `cpp`
**Base:** `main`
**Language:** C++17
**UI:** Native Win32 API
**Project goal:** Rewrite Gemma as a lightweight native Windows desktop AI agent that can both provide a Notepad-like working interface and operate Windows through explicit, auditable tools.

---

## 1. Product vision

Build a real Windows desktop application, not a terminal wrapper, web view, Electron shell, or PowerShell GUI.

The application should feel like a simple native editor/notepad with an AI conversation area, a command/input bar, menus, model selection, and optional tool/activity panels. The LLM should be able to inspect and control Windows through a well-defined native tool API: windows, clipboard, UI Automation, files, processes, services, registry, settings, networking, and command execution.

The user should not need to learn C++ or maintain the implementation. Development, architecture, coding, tests, and documentation are to be handled as part of the project.

## 2. Core requirements

- Native C++ desktop executable using Win32.
- No Electron, browser runtime, .NET, or PowerShell dependency for the application itself.
- Fast startup, low memory use, small deployment footprint, and responsive UI.
- Streaming model responses; no spinner-only interaction.
- Native menus, dialogs, controls, keyboard shortcuts, clipboard integration, notifications, and system tray support where useful.
- External configuration; do not hardcode user-specific credentials.
- Modular source tree with clear separation between UI, providers, agent, tools, Windows integration, configuration, and persistence.
- Tool calls use structured schemas and structured results, not fragile parsing of arbitrary console text.
- Tool execution is observable: show what the agent is doing, what it changed, and whether it succeeded.
- Support Windows 7 as a compatibility goal where technically practical; verify actual API, compiler, TLS, and dependency compatibility before claiming support. Newer Windows versions may expose additional capabilities.
- Keep the project isolated from the existing PowerShell Gemma/MIRA work until the user explicitly chooses to integrate or replace anything.

## 3. Proposed technology

### Language and build
- C++17 as the baseline.
- Native Win32 API for windows, messages, controls, dialogs, clipboard, process integration, and shell interaction.
- CMake for repeatable builds.
- MSVC and/or MinGW-w64 toolchains; choose and document the primary supported toolchain after a small compatibility/build spike.
- Avoid unnecessary frameworks and runtime dependencies.
- Use RAII, clear ownership, and explicit error handling. Keep Windows handles wrapped safely.

### UI and rendering
- Standard Win32 controls and common controls for the first version.
- Rich Edit control for the initial conversation/editor surface if its behavior and deployment footprint fit.
- GDI for basic drawing; consider Direct2D only if a concrete UI requirement justifies it.
- Native Open/Save dialogs, menus, accelerators, context menus, clipboard, and drag-and-drop.
- Resizable layout with optional side panels for tools, files, and activity.
- Theme support can start with system colors; optional dark/light themes later.
- Do not build a custom text editor unless Rich Edit proves insufficient.

### Networking and data
- HTTP client with streaming support (libcurl is a candidate; validate TLS and Windows 7 deployment requirements).
- JSON library (nlohmann/json is a candidate; assess size and compatibility).
- Secure credential handling using supported Windows facilities where appropriate; never commit keys or tokens.
- External settings/configuration files with validation and safe defaults.
- Session/history storage with versioned schemas and robust recovery.

## 4. High-level architecture

Keep the application divided into independently testable modules:

1. **Application / Win32 shell**
   - Entry point, main window, message loop, menus, accelerators, dialogs, layout, tray, notifications.
2. **UI layer**
   - Conversation view, input editor, model picker, status bar, tool/activity view, approval prompts.
3. **Provider layer**
   - Provider interface, authentication, request serialization, streaming parsers, error normalization, usage metadata.
4. **Agent layer**
   - Conversation state, context management, tool-call loop, cancellation, limits, planning/execution boundaries.
5. **Tool registry**
   - Tool schemas, descriptions, argument validation, permission classification, dispatch, structured results.
6. **Windows integration layer**
   - Clipboard, windows, UI Automation, screenshots, shell, filesystem, processes, registry, services, settings, networking.
7. **Persistence/configuration**
   - Settings, provider profiles, model defaults, sessions, logs, operation history.
8. **Diagnostics and tests**
   - Unit tests, integration tests, mock provider tests, Windows-version compatibility checks.

UI code must not perform blocking network or long-running tool operations on the window/message thread. Use worker threads and marshal UI updates safely to the main thread. Cancellation and shutdown must be deterministic.

## 5. Main window and user experience

Initial layout target:

- Menu bar: File, Edit, View, Tools, Model, Settings, Help.
- Toolbar: New, Open, Save/export, Attach, Run/Stop, model selector, settings.
- Main conversation/editor surface with readable streaming output.
- Input area with multiline support and Send/Stop controls.
- Status bar showing provider/model, request state, elapsed time, token usage when available, and tool activity.
- Optional side panel for tool calls, execution history, files/context, and approvals.

Interaction requirements:
- Native keyboard shortcuts and predictable focus behavior.
- Clipboard copy/paste, including Unicode; support richer clipboard formats where useful.
- Drag-and-drop files into the conversation.
- Find, select, copy, and save conversation content.
- Clear indication when the model is streaming, waiting for a tool, awaiting approval, or finished.
- Tool activity must not flood or corrupt the conversation display.
- Accessible controls and sensible keyboard navigation.
- No duplicate redraws, flicker, stuck progress indicators, or UI freezes.

## 6. LLM providers and model handling

Port the useful provider behavior from Gemma rather than inventing a new provider design without reason.

- Define a common provider interface for request, streaming response, cancellation, usage, and errors.
- Initially prioritize the providers and models that are already supported and working in the existing Gemma codebase.
- Preserve provider-specific request formats and authentication behavior; do not mix conversation payloads between providers.
- Keep model IDs and defaults in configuration.
- Model picker grouped by provider; selecting a model selects its provider.
- Support API-key candidate lists/rotation only where the existing project requirements call for it; never log credentials.
- Handle rate limits, transient server errors, timeouts, malformed responses, and provider-specific errors distinctly.
- Preserve streaming text and thought/reasoning separation where supported and explicitly configured.
- Show usage from actual response metadata; do not make extra probe requests merely to display usage.
- Grounding/web search must use the provider's supported mechanism and clearly distinguish verified source results from model-generated text.
- Keep provider capabilities explicit (streaming, tools, native search/grounding, usage, cancellation, reasoning controls).

Do not assume every existing provider implementation is correct. Audit it and reproduce behavior with tests before porting.

## 7. Agent and tool-calling engine

- Implement a provider-neutral tool registry with machine-readable schemas.
- Validate every tool name and argument before dispatch.
- Return structured success/error results to the model.
- Support bounded multi-step tool loops with configurable limits for steps, time, output size, and recursion.
- Support cancellation from the UI and safe interruption of running work.
- Preserve conversation consistency when a tool fails or a request is cancelled.
- Prevent accidental duplicate tool execution on retries or repeated streamed events.
- Separate planning from execution where useful; the model cannot silently grant itself additional permissions.
- Record tool name, validated arguments (redacting secrets), start/end time, approval decision, result summary, and error.
- Provide clear UI visibility into every tool call.
- Include a dry-run/preview mode for tools that support it.

## 8. Native Windows tool API

The central feature is a reusable native Windows automation API exposed to the LLM as individual tools. Prefer documented Windows APIs over shell commands when practical. PowerShell/CMD may remain optional tools for operations that lack a suitable native API; they must not be the foundation of the application.

### 8.1 System inspection
- Windows edition/version/build, architecture, uptime.
- CPU, memory, disks, volumes, free space, hardware summary.
- Environment variables and relevant system/user paths.
- Logged-on user context and privilege level, without exposing secrets.
- Installed applications and startup configuration where discoverable.
- Structured, bounded output with sensitive values redacted.

### 8.2 Windows and desktop interaction
- Enumerate top-level windows and relevant child windows.
- Inspect window titles, classes, visibility, ownership, and process IDs.
- Activate, minimize, maximize, restore, move, resize, and close windows.
- Respect desktop/session boundaries and Windows security restrictions.
- Use UI Automation for semantic inspection and interaction with controls when available.
- Report when an application does not expose accessible controls; do not pretend an action succeeded.

### 8.3 Clipboard
- Read and write Unicode text.
- Inspect available clipboard formats.
- Support images and file-drop formats where practical.
- Copy selected text or content from supported windows where permissions allow.
- Handle clipboard ownership, delayed rendering, contention, and large payloads safely.
- Never silently upload clipboard contents to a provider; clipboard access must be explicit and visible.

### 8.4 Keyboard, mouse, and screenshots
- Capture screenshots of the desktop, a window, or a selected region.
- Provide image data to the model only through an explicit, bounded workflow.
- Support controlled input simulation where Windows permits it.
- Prefer UI Automation actions over blind coordinate-based clicking.
- Make coordinate-based input visible and auditable.
- Do not attempt to bypass secure desktops, UAC consent, lock screens, or other OS security boundaries.

### 8.5 Filesystem and shell
- List, search, inspect, read, create, write, copy, move, rename, and delete files/directories.
- Respect access-denied errors and filesystem boundaries.
- Preview file changes and provide diffs for text edits.
- Support safe temporary files and atomic replacement where practical.
- Launch applications and open files/URLs through supported Shell APIs.
- Optional PowerShell/CMD execution with explicit command display, approval, timeout, output limits, and process-tree cancellation.
- Never execute model-generated commands invisibly.

### 8.6 Processes and applications
- Enumerate processes and inspect executable path, PID, parent, and resource information where available.
- Start processes with explicit arguments and working directory.
- Request termination and report whether it succeeded.
- Avoid force termination by default; require approval for disruptive actions.
- Enumerate installed applications and provide uninstall/launch information.
- Installation and uninstallation must be explicit, reviewable operations.

### 8.7 Registry
- Enumerate and search keys/values within permitted hives.
- Read values with correct registry types.
- Create and modify keys/values.
- Delete values/keys only with explicit approval.
- Support export/backup before modifications and restore guidance.
- Distinguish HKCU, HKLM, 32-bit and 64-bit registry views.
- Validate paths, value types, and data sizes.
- Never imply that registry changes are harmless; show exact target and proposed change.

### 8.8 Services, startup, and scheduled tasks
- Enumerate services and inspect status/configuration.
- Start, stop, pause, resume, and configure services where authorized.
- Inspect startup applications and startup folders.
- Inspect scheduled tasks and their actions/triggers.
- Changes to services, startup entries, or scheduled tasks require approval and verification.

### 8.9 Windows settings
- Inspect and, where supported, modify display, sound, power, personalization, regional, accessibility, and other settings.
- Use documented APIs or supported Windows settings interfaces.
- Clearly distinguish settings that can be changed directly from settings that require opening a Windows Settings page or user confirmation.
- Do not promise control over settings that Windows restricts or does not expose through a stable API.

### 8.10 Networking and firewall
- Inspect adapters, IP configuration, DNS, routes, connectivity, and proxy configuration.
- Provide bounded diagnostics (for example, resolve host, test connection).
- Inspect firewall profiles/rules.
- Firewall modifications require explicit approval and exact before/after reporting.
- Do not expose Wi-Fi passwords, saved credentials, or other secrets through normal inspection.

### 8.11 Devices and system administration
- Enumerate devices and inspect status where supported.
- Expose administrative operations only when the current token has the required rights.
- Use normal UAC elevation workflows when necessary; never bypass UAC.
- Explain when a reboot, sign-out, or elevated session is required.
- Make system-wide and security-sensitive changes especially visible.

## 9. Permissions, safety, and trust

Use capability-based permissions, not a single unrestricted “AI has admin” switch.

Suggested levels:
- **Read-only:** inspect system state and report.
- **Low-risk write:** reversible user-level changes, still logged.
- **Sensitive write:** registry, services, firewall, startup, application installation, system settings, and destructive file operations; require explicit approval.
- **Administrative:** operations requiring elevation; show the exact action and obtain user consent through UAC and the app's approval flow.

Requirements:
- Default to read-only inspection until the user grants a specific write action.
- Show the exact operation, target, and relevant arguments before approval.
- Separate approval for materially different actions; no blanket consent hidden in a prompt.
- Never store or transmit credentials, tokens, passwords, or private clipboard data in logs or model context unless explicitly needed and authorized.
- Redact secrets from tool results and diagnostics.
- Protect against prompt injection from web pages, files, clipboard content, and command output. Untrusted content must never be treated as permission.
- Do not let the model change its own permission policy, disable audit logs, or silently elevate.
- Maintain an append-only local operation history with timestamps and outcomes; provide a way to inspect and export it.
- Include a global Stop control and a kill/cancel path for long-running operations.
- Fail closed when validation, authorization, or verification is uncertain.

## 10. Configuration and persistence

External configuration should cover:
- Provider credentials references and provider settings.
- Default provider/model and model-specific capabilities.
- Tool enablement and per-tool permission policies.
- Timeouts, output limits, agent loop limits, and streaming options.
- UI preferences, theme, font, window layout, and shortcuts.
- Session/history settings and retention.
- Logging level and redaction behavior.

Requirements:
- Ship an example config with placeholders, never real keys.
- Validate configuration and report invalid entries clearly.
- Preserve unknown fields where possible to support forward compatibility.
- Write settings atomically and keep recoverable backups.
- Version session/config schemas and provide migration handling.
- Keep secrets out of ordinary JSON config where a Windows credential facility is appropriate.

## 11. Reliability, performance, and compatibility

- Keep network and tool work off the UI thread.
- Use bounded queues and output buffers.
- Handle cancellation, app shutdown, network loss, provider errors, and tool timeouts.
- Avoid deadlocks and unsafe cross-thread UI access.
- Use RAII for handles, sockets, streams, and allocated resources.
- Avoid unnecessary polling and background activity.
- Measure startup time, idle memory, streaming responsiveness, and large-output behavior.
- Test Unicode paths, non-English Windows installations, long paths where supported, and clipboard edge cases.
- Test on Windows 7 if it remains a supported target, plus current Windows versions.
- Document any feature unavailable on older Windows versions.
- Do not claim Windows 7 support based only on successful compilation; test runtime, TLS/networking, APIs, and packaged dependencies on an actual compatible environment.

## 12. Testing strategy

### Unit tests
- JSON/config parsing and validation.
- Provider request serialization and streaming parsers.
- Tool schema and argument validation.
- Permission decisions and approval state.
- Registry path/type handling.
- Path normalization and filesystem safety.
- Session serialization/migration.
- Redaction and audit logging.

### Integration tests
- Mock HTTP server for streaming, errors, timeouts, and cancellation.
- Provider smoke tests only when explicitly configured; never require credentials in CI.
- Tool tests in temporary directories and disposable registry keys.
- Process launch/termination tests using harmless test processes.
- Clipboard tests in an interactive Windows session.
- UI Automation tests against a controlled test window.
- Permission tests proving denied operations do not execute.

### Manual acceptance tests
- Launch from Explorer and normal shortcuts.
- Resize/minimize/restore and multi-monitor behavior.
- Copy/paste Unicode text and images.
- Stream long model responses while the UI remains responsive.
- Switch providers/models without leaking provider-specific conversation payloads.
- Cancel network requests and tool operations.
- Inspect a window, capture a screenshot, and interact with an accessible test control.
- Read and modify a disposable registry key with backup and approval.
- Inspect processes/services and test approved operations in a disposable environment.
- Confirm exact operation previews, logs, and post-action verification.
- Verify that no privileged action bypasses UAC or app approval.
- Test on supported Windows versions and document differences.

## 13. Build, packaging, and delivery

- Reproducible CMake build.
- Release and debug configurations.
- CI builds and static analysis where practical.
- Package only required runtime DLLs/data files.
- No installer requirement for the first prototype; portable folder deployment is preferred.
- Include README, configuration example, license notices for dependencies, and troubleshooting notes.
- Code-signing can be considered later; do not make it a blocker for the prototype.
- Record compiler/toolchain versions and build instructions.

## 14. Phased implementation roadmap

### Phase 0 — Audit and specification
- [ ] Audit current Gemma provider, agent, tool, settings, and session behavior.
- [ ] Identify reusable behavior and known bugs; do not blindly port defects.
- [ ] Inventory existing C and GUI branches as references only; neither is assumed to be the target architecture.
- [ ] Confirm provider priorities, Windows version targets, and dependency policy.
- [ ] Finalize architecture and threat model before implementing system-control tools.

### Phase 1 — Native application skeleton
- [ ] Set up CMake project and C++17 build.
- [ ] Create Win32 entry point, message loop, main window, menus, and status bar.
- [ ] Add native input and conversation view.
- [ ] Add worker-thread/message-queue infrastructure.
- [ ] Add logging, configuration loading, and graceful shutdown.
- [ ] Verify small executable footprint and responsive UI.

### Phase 2 — Provider foundation
- [ ] Implement provider abstraction and HTTP streaming.
- [ ] Port one primary Gemma provider end-to-end.
- [ ] Add model configuration and provider-aware model picker.
- [ ] Implement cancellation, error handling, and usage display.
- [ ] Add mock-server tests before adding further providers.

### Phase 3 — Agent and tool framework
- [ ] Implement structured tool registry and schemas.
- [ ] Implement bounded tool-call loop and structured results.
- [ ] Add approvals, permission levels, dry-run, and audit history.
- [ ] Add Stop/cancellation and duplicate-call protection.
- [ ] Test tool execution with harmless mock tools.

### Phase 4 — Essential Windows integration
- [ ] Add system information and filesystem tools.
- [ ] Add process inspection and controlled process launch.
- [ ] Add clipboard read/write with explicit access behavior.
- [ ] Add window enumeration/control and screenshot capture.
- [ ] Add UI Automation inspection/actions.
- [ ] Add optional visible PowerShell/CMD execution as fallback tools.

### Phase 5 — Advanced Windows administration
- [ ] Add registry inspection and guarded modifications with backup.
- [ ] Add services, startup entries, and scheduled task tools.
- [ ] Add settings inspection and supported settings changes.
- [ ] Add networking and firewall inspection/management.
- [ ] Add device inspection and approved administrative workflows.
- [ ] Verify UAC behavior and fail-closed permission handling.

### Phase 6 — Product polish
- [ ] Improve editor/conversation UX, keyboard shortcuts, find/copy/save.
- [ ] Add file drag-and-drop and attachment handling.
- [ ] Add tool/activity side panel and operation history viewer.
- [ ] Add themes and optional system tray behavior.
- [ ] Add configuration UI and session management.
- [ ] Optimize startup, memory, rendering, and large outputs.

### Phase 7 — Compatibility and release
- [ ] Run automated and manual acceptance suites.
- [ ] Validate Windows 7 compatibility if retained as a target.
- [ ] Test current Windows releases.
- [ ] Produce portable release package and documentation.
- [ ] Review security model and audit logs before any general use.

## 15. Explicit non-goals and constraints

- No implementation work until the user decides to start this future project.
- No changes to `main`, `thin`, root `mira.ps1`, or current Gemma PowerShell files as part of this planning branch.
- No Electron, browser-based UI, Qt, or .NET dependency unless the user explicitly changes the requirement.
- No silent or unrestricted system administration.
- No credential harvesting, security bypasses, UAC bypass, or hidden execution.
- No claim that every Windows setting or application can be controlled; capabilities depend on documented APIs, permissions, OS version, and application accessibility.
- No unnecessary custom editor or graphics engine.
- No copying old branch code without reviewing its correctness and licensing/dependency implications.

## 16. Definition of done

The project is ready for a first public release when:
- It is a genuinely native Win32 desktop application.
- It can connect to configured LLM providers and stream responses.
- The agent can call validated native tools through a bounded execution loop.
- It can inspect Windows and perform explicitly approved changes across the supported tool categories.
- Clipboard, windows, screenshots, and UI Automation work reliably in supported sessions.
- Sensitive operations are permission-gated, auditable, and verifiable.
- The UI remains responsive during network and tool activity.
- Builds, tests, packaging, configuration, and limitations are documented.
