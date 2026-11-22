# Gemma language ports

These are independent first-pass ports of `gemma.ps1`. They do not replace the Windows PowerShell implementation.

## Files

- `gemma.py` — Python 3, standard library only; intended to run on Windows, macOS, and Linux.
- `gemma.sh` — Bash implementation for Unix-like environments. Requires `bash`, `curl`, `jq`, and `openssl`; `python3` is used only to parse a pasted OAuth callback URL.

## Start

Python:

```sh
python3 gemma.py
python3 gemma.py -p "show weather"
python3 gemma.py -e "find notes.txt and open the file manager selecting it"
```

Bash:

```sh
chmod +x gemma.sh
./gemma.sh
./gemma.sh -p "show weather"
./gemma.sh -e "find notes.txt and open the file manager selecting it"
```

`-p` makes one interactive request (tool calls and permission prompts remain enabled). `-e` asks for a command only and does not execute it.

## Authentication

Both ports use the same Antigravity token location as the PowerShell script:

`~/.gemini/antigravity-cli/antigravity-oauth-token`

They can reuse an existing token file and refresh it. Token expiry is written as ISO-8601 UTC so it remains compatible with the PowerShell implementation.

For a new OAuth login, set these environment variables first:

- `AGY_GOOGLE_CLIENT_ID`
- `AGY_GOOGLE_CLIENT_SECRET`

Then run `.auth login`. The credentials are deliberately not duplicated in these new files. `GEMINI_APIJ` is retained as the Gemini Developer API key environment variable used by the existing PowerShell script.

Optional configuration:

- `GEMMA_PROVIDER=antigravity|gemini`
- `GEMMA_MODEL=<model-id>`
- `GEMMA_SEARCH_MODEL=<search-model-id>`

## Initial-port scope and known gaps

Both ports implement the core request loop, Antigravity OAuth token refresh, model listing/switching, separate Search-only preflight, basic function tools, ASK/AUTOPILOT, `.provider`, `.grounding`, `.model`, `.auth`, `-p`, and `-e`.

They are not feature-equivalent to the 2,400-line PowerShell program yet:

- The Windows-specific UI Automation, clipboard, window management, native C# helper, skill loader, rich multiline editor, spinner, and Explorer integration are not ported.
- Python currently has no persistent conversation history/session export and its `.clear`/ `.save` commands are placeholders.
- Bash currently has no persistent history/session export; its `.clear` and `.save` commands are placeholders.
- Bash uses the local Bash shell for `run_command`; the Python port uses the platform's default command shell.
- Native Search availability depends on the Google account's `webSearchModelIds` capability list and server capacity. A 503 capacity error is not repaired by changing the client language.

These are initial ports for review, not runtime-validated releases. Test them with a non-sensitive request before enabling AUTOPILOT.
