# deepseek-delegate-kit

A Claude Code skill that hands self-contained tasks to a separate Claude Code agent
running on **DeepSeek V4.1 Flash** through **OpenCode Go**, so bulk or mechanical work
doesn't use your Claude plan. It also sets up terminal `claude` to run `opusplan`:
planning on Opus with your Claude login, execution on DeepSeek.

Windows only (PowerShell). No keys are included: setup asks for your own.

## What gets installed

| Piece | Where | What it does |
|---|---|---|
| `deepseek-delegate` skill | `~\.claude\skills\deepseek-delegate\` | Tells Claude when and how to delegate; `delegate.ps1` runs the DeepSeek agent and returns its result. Available in every project, desktop app and terminal. |
| LiteLLM gateway | `127.0.0.1:4000`, config `~\.litellm\litellm-config.yaml` | Routes Claude Code's requests: Opus to Anthropic with your login, everything else to DeepSeek. |
| OpenCode filter | `127.0.0.1:4011`, `~\.litellm\opencode-filter.py` | Sits between LiteLLM and OpenCode. Forwards only allowlisted headers and authenticates with your OpenCode key. See "Why the filter matters". |
| Start script | `~\.claude\start-litellm.ps1` | Starts the filter and gateway hidden, if they aren't running. Called automatically. |
| Gateway settings | `~\.claude\gateway-settings.json` | Used only by terminal `claude`: `opusplan`, the gateway env, a 200k context cap, and a hook that starts the gateway. Your normal `settings.json` is not touched, so the desktop app keeps its defaults. |
| `claude` function | your PowerShell profile(s) | Makes `claude` in a terminal load the gateway settings. `claude.exe` bypasses it. |

## Requirements

- Windows 10/11, Windows PowerShell 5.1 (built in)
- Python 3.9+ from python.org (not the Microsoft Store stub)
- LiteLLM proxy: `python -m pip install "litellm[proxy]"` (setup offers to do this)
- Claude Code, native build, signed in (`claude.exe` in `%USERPROFILE%\.local\bin` or on PATH)
- An **OpenCode Go** subscription and its API key
- For terminal `opusplan`: a Claude Pro or Max login in Claude Code

## Install

Unzip, open PowerShell in the folder, and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
```

Setup asks for your OpenCode key (hidden input), checks it against OpenCode before
saving it as the user variable `OPENCODE_API_KEY`, generates a random
`LITELLM_MASTER_KEY`, installs the files, and sends a test request through the gateway.
Re-running it is safe; existing files are backed up as `*.bak-<timestamp>`.

## Use

- **Desktop app or terminal:** "delegate writing tests for utils.py to DeepSeek", or
  "have flash rename X across the repo". Claude writes a self-contained prompt, runs the
  agent, and checks its work.
- **Terminal:** open a new PowerShell window and run `claude`. The first start takes
  10-15 s while the gateway comes up.

## What leaves your machine

- **To OpenCode:** the delegated task and everything the DeepSeek agent reads or runs;
  in terminal sessions, all non-Opus requests. Don't delegate work involving secrets.
- **To Anthropic:** Opus requests (Plan mode in terminal `opusplan`), with your login.
- Your Claude login never goes to OpenCode (see below).

## Why the filter matters

When a request carries a Claude login token, LiteLLM's Anthropic provider sends that
token upstream **instead of** the API key you configured. Pointing LiteLLM straight at
OpenCode would therefore hand your Claude login to OpenCode. The filter drops every
header not on its allowlist and always sets your OpenCode key itself. **Never point
`api_base` directly at opencode.ai.** If the filter is down, DeepSeek requests fail
instead of going out unfiltered.

The filter also rewrites three things OpenCode rejects: mid-conversation `system`
messages (sent after plan approval), `redacted_thinking` blocks, and regex `pattern`
rules in tool schemas (the built-in Artifact tool has one).

## Troubleshooting

- Logs: `%USERPROFILE%\.litellm\litellm-4000.log` and `opencode-filter.log`. OpenCode
  errors are logged there with the request's shape (no message content).
- To save the full failing request for debugging, set the user variable
  `OPENCODE_FILTER_DUMP=1`, restart the filter, and reproduce; it writes
  `last-failed-request.json` (includes your conversation) next to the filter.
- Restart everything: stop the `python.exe`/`litellm.exe` processes for ports 4000/4011,
  then run `~\.claude\start-litellm.ps1`.
- "unrecognized_model" notices on stderr are harmless.

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1              # keep keys
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -RemoveKeys  # also remove them
```
