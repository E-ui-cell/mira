# GEMMA Desktop

Native Windows desktop interface for GEMMA, built with Windows PowerShell 5.1 and Windows Forms. It runs as a normal window; it does not open a terminal UI.

## Launch

Double-click `gemma-gui.vbs` to start GEMMA without a console window.

Or run from PowerShell:

    powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File .\gemma\gemma.ps1

Windows PowerShell 5.1 is the target runtime. No external PowerShell modules, browser runtime, or package installation is required.

The former terminal interface is preserved as `gemma\gemma-cli.ps1`.

## Layout

The window is intentionally simple, like a compact editor:

- File, Edit, View, Settings, and Help menus
- Read-only conversation transcript with separate user, assistant, and error colors
- Multiline prompt editor; Ctrl+Enter sends
- Provider, model, and reasoning-effort controls
- Send, Stop, Speak, and Replay actions
- Text-file insertion and transcript export
- Request duration and token counts in the status bar

## One-shot behavior

Every Send is an independent request. Only the current prompt is sent to the model. Earlier messages remain visible in the local window transcript but are not sent as conversational context. Gemini tool calls and their results remain inside the same request.

The application runs requests and speech work in background PowerShell runspaces, so the window remains responsive while they execute. Stop cancels the active worker.

## Providers

This first desktop build reuses the existing GEMMA providers:

- `antigravity`: existing Antigravity OAuth token store
- `gemini`: Gemini Developer API using `GEMINI_API` or `GEMINI_API_KEY`

OpenAI is not wired into this GUI build yet; it remains a separate provider task. Model IDs can be entered directly in the Model field.

PowerShell tools requested by the model use a native Yes/No confirmation dialog. API credentials are read from the existing environment variables or Antigravity token store. They are never written to the GUI config.

## External configuration

On first launch, the example config is copied to:

    %USERPROFILE%\.gemma\gemma-gui.json

It stores provider, model, effort, selected theme, font family and size, window size and position, optional system-prompt file, and custom themes. It does not store API keys.

Changes are saved automatically. You can also choose Settings -> Save external config now.

## Fonts and themes

View -> Choose font opens the native Windows font picker. Font family and size are saved externally.

Built-in themes:

- Gruvbox Dark
- Solarized Dark
- Solarized Light
- Dracula
- Nord
- One Dark

Custom themes can be added under `CustomThemes` in the JSON file. Each custom theme must provide all ten colors:

`Background`, `Surface`, `Input`, `Foreground`, `Muted`, `Accent`, `User`, `Assistant`, `Error`, and `Border`.

Example:

    "CustomThemes": {
      "My Theme": {
        "Background": "#282828",
        "Surface": "#3C3836",
        "Input": "#32302F",
        "Foreground": "#EBDBB2",
        "Muted": "#A89984",
        "Accent": "#FABD2F",
        "User": "#83A598",
        "Assistant": "#B8BB26",
        "Error": "#FB4934",
        "Border": "#504945"
      }
    }

## TTS

Speak generates speech when no cached WAV exists and otherwise plays the cached WAV. Replay is cache-only and never asks the TTS API to generate another file. The existing Gemini TTS voice, director notes, and audio cache are reused unchanged.

## Current scope

This is the first native GUI replacement, not a full port of every terminal command. It currently supports one-shot text chat, the existing Gemini/Antigravity tool cycle, native PowerShell approval, text-file insertion, transcript export, themes, fonts, and cached TTS playback. Model discovery, image/file multimodal attachment workflows, OpenAI provider support, and rich Markdown/code rendering are not yet implemented in this desktop shell.
