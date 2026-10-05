# MIRA

Minimal LLM TUI for **Windows 7 SP1 / Windows PowerShell 5.1**.

## TL;DR

```text
┌───  1.7s      ↑ 30  ↓ 353 ───────────────────────────────────────────────┐
  Master Heading

  │ quoted text

  Normal Markdown, inline math, lists, tables, JSON

  ∙∙ PYTHON ∙∙∙∙∙∙∙∙∙∙∙∙∙
  print('hello')
  ∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙
└───────────────────────────────────────────────────────────────────────────┘
> 
```

No PSReadLine. Native console input. Markdown renderer, code blocks, math, tables.

## Quickstart

Set at least one provider API key:

```powershell
$env:GEMINI_API_KEY='YOUR_KEY'
```

Download:

```powershell
iwr "https://raw.githubusercontent.com/E-ui-cell/mira/main/mira.ps1" -OutFile "$env:USERPROFILE\Downloads\mira-tui\mira.ps1"
```

Run:

```powershell
powershell.exe -NoProfile -File "$env:USERPROFILE\Downloads\mira-tui\mira.ps1"
```

Default model can be set with `GEMINI_MODEL`.

## Internal commands

| Command | Purpose |
|---|---|
| `.help` | Show commands |
| `.model <provider:model>` | Switch provider/model |
| `.models` | Show cached chat models |
| `.models` + `Tab` | Refresh model caches |
| `.providers` | Show provider registry |
| `.session [name]` | Start RAM-only context session |
| `.empty session` | Clear session context |
| `.compress session` | Summarize older session messages |
| `.delete session` | Leave session and discard context |
| `.file <path>` | Send text/image file |
| `.read <path>` | Send a text file |
| `.shot [path]` | Send clipboard/image |
| `.diff <a> <b>` | Send a file diff |
| `.request` | Show last request summary |
| `.request json` | Show raw request JSON |
| `.save [name]` | Save fenced code blocks as source files |
| `.copy` | Copy raw last response |
| `.grab [name.txt]` | Save raw last response as TXT |
| `.ui on/off` | Toggle Markdown rendering |
| `.stream on/off` | Toggle OpenAI-compatible streaming |
| `.reasoning on/off` | Toggle reasoning output |
| `.clear` | Clear screen |
| `.clear history` | Clear saved history |
| `.history` | Show history |
| `.history persist on/off` | Toggle history persistence |
| `.q` / `:q` / `:wq` | Quit |

## Functional

- Gemini and OpenAI-compatible providers
- Multiple provider/model selection
- Persistent command history
- Multiline input and native readline
- Text and image file input
- Clipboard screenshots
- File diffs
- RAM-only sessions and session compression
- Streaming and reasoning output for supported providers
- Markdown rendering with quotes, emphasis, code blocks, math, lists, tables and JSON
- Raw response access is preserved for `.copy`, `.grab` and `.save`

## Not yet done

- CLI flags `-m`, `-e`, `-h` and `--` are not implemented
- Renderer edge cases are still being refined

## Release

Releases are created automatically from version tags such as `v1.0.0`.

## License

See the repository for the current project status and release history.
