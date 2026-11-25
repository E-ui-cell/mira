# MIRA

**An aichat alternative for Windows PowerShell 5.1**, with a small set of compatible command concepts and a native console TUI.

Wrapper for LLMs  

## TL;DR

```text
┌───  1.7s      ↑ 30  ↓ 353  ● ───────────────────────────────────────────┐
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

The status line shows request time and token counts. When a session is enabled, it also shows `●`, for example:

```text
...  1.7s      ↑ 30  ↓ 353  ●
```

Markdown-aware TUI renderer with code, math, tables, quotes and JSON.

Native file/image input, diff sending, on-demand sessions with export, model discovery and Google/OpenAI-compatible streaming.

## Quickstart

MIRA starts with **Gemini** as the default provider.

Default model selector (edit `DefaultModel` near the top of `mira.ps1`):

```powershell
DefaultModel = 'gemini:gemini-3.5-flash-lite'
# Or: 'antigravity:gemini-3.1-flash-lite'
```

The selector uses the same `provider:model` format as aichat. Provider and model are parsed from this single setting.

To use Google Antigravity instead, sign in and load its account-specific model list:

```text
.auth login
.models antigravity
.model antigravity:<model>
```

Set the Gemini API key:

```powershell
$env:GEMINI_API_KEY="YOUR_KEY"
```

Or use NVIDIA NIM with a key from the [NVIDIA API Catalog](https://build.nvidia.com/):

```powershell
$env:NVIDIA_API_KEY="YOUR_KEY"
```

Then, inside MIRA, select the documented Nemotron 3.5 Lightning model:

```text
.model nvidia:nvidia/nemotron-3.5-lightning-30b-a3b
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

Or refresh one provider directly:

```text
.models antigravity
```

Refresh uses providers with a non-empty API-key environment variable. Antigravity is refreshed separately when its OAuth token is present. NVIDIA uses the documented hosted text-chat model catalogue bundled with MIRA: the hosted API documents model-specific chat endpoints, but not a shared `/v1/models` discovery endpoint.

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

| Provider | Authentication |
|---|---|
| Gemini | API key: `GEMINI_API_KEY` |
| Antigravity | Google OAuth: `.auth login` (no API key) |
| OpenRouter | `OPENROUTER_API_KEY` |
| Groq | `GROQ_API_KEY` |
| OpenAI | `OPENAI_API_KEY` |
| NVIDIA NIM | `NVIDIA_API_KEY` |
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

The normal operating mode is **one-shot**. To start every run with a RAM-only conversation session, change `SessionEnabled` near the top of `mira.ps1` to `$true`; leave it `$false` for one-shot requests. This setting is separate from persistent command history (`PersistHistory`).

Every prompt is sent as an independent request unless a session is enabled.

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

Markdown rendering is **off by default**. Enable it to use the terminal renderer, or leave it off to show the raw model response:

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

Streaming is **on by default** for Gemini, Antigravity, NVIDIA NIM, and other OpenAI-compatible providers. Gemini and Antigravity use Google's SSE endpoint; NVIDIA uses its OpenAI-compatible SSE endpoint and exposes Nemotron reasoning through `reasoning_content`. Toggle streaming with:

```text
.stream on
```

Disable it with:

```text
.stream off
```

Thought-summary output is configured independently for each provider in the settings block near the top of `mira.ps1`:

```powershell
ReasoningOutput = [ordered]@{
    gemini      = $null
    antigravity = $null
    openrouter  = $null
    groq        = $null
    openai      = $null
    nvidia      = $null
    deepseek    = $null
    mistral     = $null
    together    = $null
    fireworks   = $null
    xai         = $null
    perplexity  = $null
}
NvidiaReasoningBudget = 4096
```

`$null` leaves the request untouched and follows that provider endpoint's defaults; MIRA displays any thought summaries the endpoint returns. Set a provider to `$true` to explicitly request output where supported, or `$false` to suppress it. Gemini and Antigravity send `includeThoughts=true/false` only when explicitly overridden. This displays provider-supplied summaries, not the model's private full reasoning trace.

For Nemotron 3.5 Lightning, `$null` leaves the endpoint's thinking default untouched. An explicit `$false` sends `enable_thinking=false`; `$true` sends `enable_thinking=true` and applies `NvidiaReasoningBudget`.

Runtime controls affect only the selected provider:

```text
.reasoning
.reasoning on
.reasoning off
.reasoning nvidia on
.reasoning antigravity off
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
| `.models <provider>` | Refresh that provider's model list |
| `.models test` | Probe candidate models |
| `.providers` | Show built-in providers |
| `.auth login/status/logout` | Sign in to or inspect Google Antigravity OAuth |
| `.request` | Show last request summary |
| `.request json` | Show raw last request JSON |
| `.save [name]` | Save fenced code blocks |
| `.copy` | Copy raw last response |
| `.grab [name.txt]` | Save raw last response |
| `.ui on/off` | Enable/disable renderer |
| `.stream on/off` | Toggle Gemini, Antigravity, NVIDIA NIM, and other OpenAI-compatible streaming |
| `.reasoning on/off` | Toggle thought output for the current provider |
| `.reasoning <provider> on/off` | Set thought output for one provider |
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
-h, --help
--
```

### Execute mode

Generate a command for the current Windows shell and execute it after confirmation:

```powershell
.\mira.ps1 -e "find all .log files under the current directory"
```

MIRA detects whether it was launched from `cmd.exe` or PowerShell and tells the LLM the detected OS and shell. The generated command is shown before execution and must be confirmed with `Y`.

For an explicit shell override:

```powershell
$env:MIRA_SHELL="cmd"
.\mira.ps1 -e "list files sorted by size"
```

Supported values are `cmd` and `powershell`.

## Configuration

There is no provider JSON configuration file.

Provider definitions are built into the script. The editable defaults and API-key environment-variable names are grouped near the beginning of `mira.ps1`. Add alternative environment-variable names to a provider's array there; the first non-empty variable is used. Antigravity uses the OAuth settings in that same block rather than an API key.

API keys use environment variables:

```text
GEMINI_API_KEY
OPENROUTER_API_KEY
GROQ_API_KEY
OPENAI_API_KEY
NVIDIA_API_KEY
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

The current beta includes the native readline/TUI, built-in providers, API-key and Antigravity OAuth authentication, one-shot requests, RAM-only sessions that can be enabled on demand and exported to a file, session compression, persistent history, model-list caching and refresh, model probing, Markdown rendering, file/text/image input, clipboard screenshots, diffs, output saving/copying, Google, NVIDIA NIM, and other OpenAI-compatible streaming, reasoning display, request inspection and raw-response mode.

### Not yet done

MIRA does not currently implement the full aichat CLI surface or a persistent session/database system.

## Release

Releases are created automatically from version tags such as `v0.1.0-beta.3`.

## More info

AI Co-pilot: **GPT-5.6 Luna**, Git copilot.

MIRA takes its name from Mira (Omicron Ceti), the “wonderful” variable star in Cetus.


## License

See the repository for the current project status and release history.
