# Gemma C

A single-source, cross-platform C client for Google Gemini and Antigravity OAuth.

## Build

The program is one C source file. It uses **libcurl** for HTTPS and **OpenSSL** for SHA-256/PKCE on Unix-like systems. JSON parsing is embedded; no JSON package, Python, Bash, PowerShell, jq, or runtime interpreter is required.

Linux (Debian/Ubuntu):

```sh
sudo apt install build-essential libcurl4-openssl-dev libssl-dev
cc -O2 -std=c11 gemma.c -lcurl -lcrypto -o gemma
```

macOS (Homebrew):

```sh
brew install curl openssl
cc -O2 -std=c11 gemma.c $(pkg-config --cflags --libs libcurl openssl) -o gemma
```

Windows (MSYS2 MinGW64 shell):

```sh
pacman -S --needed mingw-w64-x86_64-gcc mingw-w64-x86_64-curl mingw-w64-x86_64-openssl
gcc -O2 -std=c11 gemma.c -lcurl -lcrypto -lbcrypt -lws2_32 -lshell32 -o gemma.exe
```

## Run

```sh
./gemma
./gemma -p "show weather"
./gemma -e "find notes.txt and open the file manager selecting it"
```

- `-p`: one interactive request; local tool calls and ASK confirmations remain enabled.
- `-e`: command suggestion only; no tools are exposed and nothing is executed.
- `.multi`: enter multiline paste mode; finish by entering `.end` on its own line.

## Commands

- `.model` — fetch the current provider's model catalogue and choose by number or ID; `.model ID` selects directly.
- `.provider antigravity|gemini`
- `.effort low|medium|high` — Gemini 3 uses `thinkingLevel`; Gemini 2.5 uses `thinkingBudget`.
- `.grounding on|off` — Search runs as a separate Antigravity OAuth request. It is never combined with function declarations in one request.
- `.ask` — each local command asks for confirmation; Enter means Yes (default).
- `.autopilot` — local commands run without per-command confirmation.
- `.verbose on|off` — request thought summaries where supported.
- `.auth login|status|logout`
- `.save` saves the current session; `.exportsession PATH` and `.loadsession PATH` export/import it. The default is `~/.gemini/gemma-session.json`.
- `.clear`, `.help`, `.q`

## Authentication and configuration

Antigravity uses the shared token file:

`~/.gemini/antigravity-cli/antigravity-oauth-token`

The client reuses and refreshes that token. For a new OAuth login, provide:

- `AGY_GOOGLE_CLIENT_ID`
- `AGY_GOOGLE_CLIENT_SECRET`

The C source intentionally contains no OAuth client credentials. This also means refresh of an expired token requires those environment variables.

Gemini Developer API uses the existing `GEMINI_APIJ` environment variable.

Optional environment variables:

- `GEMMA_PROVIDER=antigravity|gemini`
- `GEMMA_MODEL=<model-id>`
- `GEMMA_SEARCH_MODEL=<model-id>`
- `GEMMA_EFFORT=low|medium|high`

## Scope and current limitations

Implemented in this first C pass: Antigravity OAuth token reuse/refresh/login, Gemini API requests, model catalogue, Gemini 3/2.5 effort controls, Search-only grounding preflight, function calling, quick weather/IP/cheatsheet lookups, local shell commands with ASK/AUTOPILOT, multiline input mode, and `-p`/`-e`.

Not yet ported from the PowerShell application: Windows UI Automation and native desktop helpers, clipboard/window controls, skill loading, Explorer-specific integration, spinner, Windows UI Automation and native desktop helpers, clipboard/window controls, skill loading, Explorer-specific integration, and spinner. The command runner captures and returns stdout/stderr (up to 20,000 characters) while also displaying it in the terminal.

A Search capacity or account-entitlement error is a Google-side limitation; changing the implementation language cannot fix a 503 `MODEL_CAPACITY_EXHAUSTED` response.

This source has not yet been runtime-validated on Windows, macOS, or Linux. Do not treat the C port as a tested release until the build checks pass on those platforms.
