# MIRA

**An aichat alternative for Windows 7 / Windows PowerShell 5.1**, with a small set of compatible command concepts and a native console TUI.

Minimal LLM TUI for **Windows 7 SP1 / Windows PowerShell 5.1**.

AI Co-pilot: **GPT-5.6 Luna**, Git copilot.

MIRA takes its name from Mira (Omicron Ceti), the “wonderful” variable star in Cetus.

## TL;DR

```text
┌───  1.7s      ↑ 30  ↓ 353 ───────────────────────────────────────────────┐
  Master Heading

  │ quoted text

  Normal Markdown, inline math, lists, tables, JSON

  ∙∙ PYTHON ∙∙∙∙∙∙∙∙∙∙∙∙
  print('hello')
  ∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙
└───────────────────────────────────────────────────────────────────────────┘
>
```

Own readline. No PSReadLine. No external modules. No config file required — for basic use, only a provider API key is needed.

MIRA is designed as an **aichat alternative for Windows 7 / Windows PowerShell 5.1**, with some familiar and compatible command concepts, while remaining a standalone implementation.

Default mode is **one-shot**: each prompt is sent independently without persistent conversational context.

A RAM-only **session mode** can be enabled when conversational context is needed. The active session is indicated on the status line.

The status line shows request time and token counts, for example:

```text
...  1.7s      ↑ 30  ↓ 353
```

Markdown-aware TUI renderer with code, math, tables, quotes and JSON.

Native file/image input, diff sending, on-demand sessions with export, model discovery and OpenAI-compatible streaming.

## Quickstart

MIRA starts with **Gemini** as the default provider.

Default model:

```text
gemini-flash-lite-latest
```

Set the API key:

```powershell
$env:GEMINI_API_KEY="YOUR_KEY"
```

Download:

```powershell
iwr "https://raw.githubusercontent.com/E-ui-cell/mira/main/mira.ps1" -OutFile "$env:USERPROFILE\Downloads\mira.ps1"
```

Run normally from the directory containing the script:

```powershell
.\mira
```

You can also run the script explicitly:

```powershell
powershell.exe -NoProfile -File ".\mira.ps1"
```

From Windows Explorer, right-click `mira.ps1` and choose **Run with PowerShell**.

No provider config file is required. The provider registry, endpoints and built-in fallback model entries are compiled into the script.

### Model discovery

`.models` shows the cached text-chat model list.

Press **Tab** after `.models` to explicitly refresh provider model lists from their APIs:

```text
.models
```

or:

```text
.models <provider><Tab>
```

The refresh only uses providers that have a non-empty API-key environment variable.

MIRA filters returned catalogs using provider metadata when available and keeps a local cache.

### Model probing

```text
.models test
```

This is an **active API probe**, not just a local check.

MIRA sends a tiny standalone request:

```text
Reply with exactly OK.
```

It probes candidate models, skips obvious non-chat families, handles rate limits, and remembers successful models.

**Caution:** `.models test` makes real API requests and can consume provider quota/rate limits.

## Providers

Built-in providers:

| Provider | API key environment variable |
|---|---|
| Gemini | `GEMINI_API_KEY` |
| OpenRouter | `OPENROUTER_API_KEY` |
| Groq | `GROQ_API_KEY` |
| OpenAI | `OPENAI_API_KEY` |
| DeepSeek | `DEEPSEEK_API_KEY` |
| Mistral | `MISTRAL_API_KEY` |
| Together | `TOGETHER_API_KEY` |
| Fireworks | `FIREWORKS_API_KEY` |
| xAI | `XAI_API_KEY` |
| Perplexity | `PERPLEXITY_API_KEY` |

Switch provider/model with:

```text
.model provider:model
```

Example:

```text
.model openrouter:some/model
```

Successful text-chat models are remembered in the local `used.list` cache for fast `.model` completion.

## One-shot and sessions

The normal operating mode is **one-shot**.

Every prompt is sent as an independent request unless a session is explicitly enabled.

Start a RAM-only session:

```text
.enable-session
```

Or give it a name:

```text
.enable-session project
```

The active session is indicated on the status line.

Clear the active session context:

```text
.empty session
```

Compress older conversation context:

```text
.compress session
```

End the session and discard its context:

```text
.delete session
```

Export the active session to a Markdown file:

```text
.export-session
```

Or choose a file name:

```text
.export-session project.md
```

Session export includes session metadata, any compressed summary, and the conversation text. Image attachments are recorded as attachment markers rather than embedded binary data.

Session context is memory-only and is not saved as a persistent MIRA session database.

## What MIRA can do

### Readline / TUI input

MIRA includes its own console readline instead of depending on PSReadLine.

It supports:

- command and path completion
- model completion
- Tab completion menus
- history navigation
- fish-like prefix history search
- multiline input with `Ctrl+Enter` / `Ctrl+J`
- `Ctrl+A`, `Ctrl+E`, `Ctrl+B`, `Ctrl+F`
- word movement and deletion
- kill/yank operations
- undo with `Ctrl+_`
- `Ctrl+L` terminal repaint
- `Alt+B`, `Alt+F`, `Alt+D`, `Alt+Backspace`
- `!command` local PowerShell execution

### Files, text and images

Send a file:

```text
.file path
```

`.file` automatically treats recognized image files as images and other files as UTF-8 text.

Read a text file explicitly:

```text
.read path
```

Send an image:

```text
.shot path
```

With no path, `.shot` uses an image from the Windows clipboard.

Current test-build limits are 2 MB for text files and 8 MB for images.

### Diff

Generate and send a simple line-by-line diff:

```text
.diff file1 file2
```

### Save / copy output

Save fenced code blocks as source files:

```text
.save
```

A response containing multiple fenced blocks saves them separately using language-based extensions where possible.

Copy the complete raw response:

```text
.copy
```

Save the complete raw response as a text file:

```text
.grab
```

### Response rendering

MIRA renders common Markdown directly in the Windows console:

- headings
- lists
- blockquotes
- bold / italic / strike
- inline code
- code blocks
- inline and display math
- tables
- JSON
- semantic terminal formatting

Disable the renderer and show the raw model response:

```text
.ui off
```

Enable it again:

```text
.ui on
```

Check state:

```text
.ui
```

### Streaming and reasoning

OpenAI-compatible streaming can be enabled with:

```text
.stream on
```

Disable it with:

```text
.stream off
```

Provider reasoning output can be toggled with:

```text
.reasoning on
.reasoning off
```

### History

History persistence is enabled by default.

View history:

```text
.history
```

Disable persistence:

```text
.history persist off
```

Re-enable it:

```text
.history persist on
```

Clear history:

```text
.clear history
```

### Request inspection

Show a summary of the last API request:

```text
.request
```

Show the raw JSON request:

```text
.request json
```

## Command reference

| Command | Function |
|---|---|
| `.help` | Show built-in help |
| `.clear` | Clear the console |
| `.history` | Show command history |
| `.history persist on/off` | Toggle persistent history |
| `.clear history` | Clear history |
| `.file <path>` | Send text or image file |
| `.read <path>` | Send UTF-8 text file |
| `.shot [path]` | Send image or clipboard image |
| `.diff <a> <b>` | Send a simple file diff |
| `.model` | Show current provider/model |
| `.model <provider:model>` | Switch provider/model |
| `.models` | Show cached text-chat models |
| `.models <provider><Tab>` | Refresh provider model list |
| `.models test` | Probe candidate models |
| `.providers` | Show built-in providers |
| `.request` | Show last request summary |
| `.request json` | Show raw last request JSON |
| `.save [name]` | Save fenced code blocks |
| `.copy` | Copy raw last response |
| `.grab [name.txt]` | Save raw last response |
| `.ui on/off` | Enable/disable renderer |
| `.stream on/off` | Toggle OpenAI-compatible streaming |
| `.reasoning on/off` | Toggle reasoning output |
| `.enable-session [name]` | Start RAM-only session |
| `.empty session` | Clear active session context |
| `.export-session [name]` | Export active session to a file |
| `.compress session` | Compress older session context |
| `.delete session` | End and discard session |
| `.q`, `:q`, `:wq`, `quit` | Exit |
| `!command` | Run a local PowerShell command |

## aichat familiarity

MIRA is intended as an **aichat alternative**, particularly for the Windows 7 / Windows PowerShell 5.1 environment.

It uses some familiar sigoden/aichat-style concepts, including:

- model selection
- sessions
- file input
- `--dry-run`
- dot-command driven interactive controls

MIRA is **not a drop-in replacement for aichat** and does not attempt to reproduce its entire CLI or configuration system.

## CLI arguments

Currently implemented:

```text
-d
--dry-run
```

The following aichat-style CLI options are not currently implemented:

```text
-m, --model
-e, --execute
-h, --help
--
```

## Configuration

There is no provider JSON configuration file.

Provider definitions are built into the script.

API keys use environment variables:

```text
GEMINI_API_KEY
OPENROUTER_API_KEY
GROQ_API_KEY
OPENAI_API_KEY
DEEPSEEK_API_KEY
MISTRAL_API_KEY
TOGETHER_API_KEY
FIREWORKS_API_KEY
XAI_API_KEY
PERPLEXITY_API_KEY
```

Optional MIRA environment settings include history, compression, model-test and cache controls.

## Platform

Target:

```text
Windows 7 SP1
Windows PowerShell 5.1
```

MIRA is intentionally kept compatible with Windows PowerShell 5.1 and the classic Windows console environment.

No PSReadLine.
No external PowerShell modules.
No PS7-specific runtime requirement.

## Status

### Functional

The current beta includes the native readline/TUI, built-in providers, API-key based configuration, one-shot requests, RAM-only sessions that can be enabled on demand and exported to a file, session compression, persistent history, model-list caching and refresh, model probing, Markdown rendering, file/text/image input, clipboard screenshots, diffs, output saving/copying, OpenAI-compatible streaming, reasoning display, request inspection and raw-response mode.

### Not yet done

MIRA does not currently implement the full aichat CLI surface or a persistent session/database system.

## Release

Releases are created automatically from version tags such as `v0.1.0-beta.3`.


## License

See the repository for the current project status and release history.
