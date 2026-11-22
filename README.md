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

Own readline. No PSReadLine dependency. No external PowerShell modules required. Use a Gemini API key or connect Antigravity with Google OAuth; optional tool modules and Markdown skills extend MIRA.

MIRA is designed as an **aichat alternative for Windows 7 / Windows PowerShell 5.1**, with some familiar and compatible command concepts, while remaining a standalone implementation.

Default mode is **one-shot**: each prompt is sent independently without persistent conversational context.

A RAM-only **session mode** can be enabled when conversational context is needed. The active session is indicated on the status line.

The status line shows request time and token counts. When a session is enabled, it also shows `●`, for example:

```text
...  1.7s      ↑ 30  ↓ 353  ●
```

Markdown-aware TUI renderer with code, math, tables, quotes and JSON.

Native file/image input, diff sending, on-demand sessions with export, model discovery and OpenAI-compatible streaming.

## Quickstart

MIRA starts with **Gemini Developer API** as the default provider. Antigravity OAuth is an additional provider and shares its token file with Gemma.

Connect Antigravity:

    .auth login
    .provider antigravity
    .grounding status

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

# Optional bundled tool modules (the script itself remains standalone)
$tools = "$env:USERPROFILE\.mira\tools"
New-Item -ItemType Directory -Force -Path $tools | Out-Null
iwr "https://raw.githubusercontent.com/E-ui-cell/mira/main/mira/tools/file-system.ps1" -OutFile "$tools\file-system.ps1"
iwr "https://raw.githubusercontent.com/E-ui-cell/mira/main/mira/tools/system-info.ps1" -OutFile "$tools\system-info.ps1"
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

Use `.models refresh` to explicitly refresh all available provider catalogues, or `.models refresh antigravity` to refresh only the Antigravity OAuth catalogue:

    .models refresh
    .models refresh antigravity

Antigravity model discovery uses the signed-in account's fetchAvailableModels catalogue; API-key providers use their model-list endpoints. Model completion itself remains local and never fetches the network.

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
| Antigravity | Google OAuth (.auth login) |
| Gemini Developer API | `GEMINI_API_KEY` |
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

## Antigravity OAuth and Google Search grounding

Antigravity OAuth is a separate answer provider. It uses Google's native server-side Google Search grounding in the same answer request. MIRA does not attach its client-side web_search function to Antigravity answer models.

Connect and manage OAuth:

    .auth login
    .auth status
    .provider antigravity
    .grounding status
    .grounding off
    .grounding on
    .auth logout

The OAuth token is stored in the shared Gemma location under the user profile: .gemini\antigravity-cli\antigravity-oauth-token. MIRA refreshes expired access tokens automatically.

For Gemini Developer API answer models, the optional client-side web_search function runs a separate Antigravity OAuth research request. It is disabled by default; set MIRA_ENABLE_AGENTIC_WEB_SEARCH=1 to enable it. MIRA_SEARCH_MODEL selects the research model (default: gemini-3.1-flash-lite). Both paths require Antigravity OAuth for Google Search.

MIRA reports grounding queries and source URLs when Google returns grounding metadata. Enabling grounding is not proof that a search occurred; missing metadata is reported as unverified.

## Tools and skills

Built-in function tools include:

- get_current_datetime — local date/time and timezone
- run_powershell — local Windows PowerShell, permission-gated
- quick_web — weather (wttr.in), public IP (api.ipify.org), and cheat sheets (cht.sh)
- get_skill — load a task playbook on demand
- web_search — Gemini Developer API only, when agentic web search is enabled

Repository tool modules in mira/tools add bounded file search/read and system information. User modules can be placed in %USERPROFILE%\.mira\tools; user-authored Markdown skills go in %USERPROFILE%\.mira\skills.

Use .tools, .skills, and .skill <name> to inspect the extension system. Read mira/tools/README.md before writing a tool module. PowerShell modules are executable code and must be reviewed before loading.

Permission mode defaults to ASK. Tool actions that require approval prompt with Enter = Yes. Use .ask to restore confirmation and .autopilot to allow model-requested tool actions without confirmation. Skills never grant permissions.

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
| `.providers` | Show built-in providers and credential status |
| `.provider <name>` | Switch answer provider |
| `.auth login/status/logout` | Manage Antigravity OAuth |
| `.grounding on/off/status` | Toggle Google Search grounding |
| `.models refresh [provider]` | Refresh provider model catalogues |
| `.tools` | List built-in and modular tools |
| `.skills` / `.skill <name>` | List/load skills |
| `.ask` / `.autopilot` | Set tool permission mode |
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

Implemented CLI arguments:

```text
-m, --model <provider:model>
-e, --execute
-d, --dry-run
-h, --help
--
```

`-e` generates a command for the detected Windows shell and executes it only after confirmation. `-d` prints the request JSON without sending it. `-m` selects a provider/model for the one-shot request.

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

Optional MIRA environment settings include history, compression, model-test and cache controls, `MIRA_ENABLE_AGENTIC_WEB_SEARCH`, and `MIRA_SEARCH_MODEL`. `AGY_GOOGLE_CLIENT_ID` and `AGY_GOOGLE_CLIENT_SECRET` can override the Antigravity OAuth client values.

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

The current beta includes the native readline/TUI, Gemini Developer API and Antigravity OAuth providers, native Antigravity Google Search grounding, optional Gemini API web_search through Antigravity OAuth, model discovery, a function-tool loop, ASK/AUTOPILOT permissions, built-in and modular tools, on-demand built-in/user skills, one-shot requests, RAM-only sessions, session compression, persistent history, model caching, Markdown rendering, file/text/image input, diffs, output saving/copying, OpenAI-compatible streaming, reasoning display and request inspection.

### Not yet done

MIRA does not implement the full aichat CLI surface or a persistent session/database system. Live OAuth, grounding, and Windows runtime behavior still require testing on the target Windows PowerShell 5.1 host.

## Release

Releases are created automatically from version tags such as `v0.1.0-beta.3`.

## More info

Project development notes are maintained in `ai.log`.

MIRA takes its name from Mira (Omicron Ceti), the “wonderful” variable star in Cetus.


## License

See the repository for the current project status and release history.
