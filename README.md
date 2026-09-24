# deepseek-delegate

A Claude Code skill that hands self-contained tasks to a separate Claude Code agent
running on a cheaper model through **your own API provider**, so bulk or mechanical
work doesn't use your Claude plan. The default is **DeepSeek V4.1 Flash on OpenCode Go**;
**OpenRouter** and any **OpenAI-compatible** or **Anthropic-compatible** API work too.

Claude Code itself stays on its default settings, in the desktop app and in the terminal.
Only the delegated agent uses the provider you choose.

Windows only (PowerShell). No keys are included: setup asks for your own.

## Providers

| `-Provider` | For | You supply |
|---|---|---|
| `opencode` (default) | OpenCode Go | an OpenCode Go key. Model defaults to `deepseek-v4.1-flash`. |
| `openrouter` | OpenRouter | an OpenRouter key and a model id, e.g. `deepseek/deepseek-chat` |
| `openai-compatible` | Groq, Together, Fireworks, DeepInfra, a local Ollama or LM Studio, and anything else that speaks OpenAI `chat/completions` | the base URL ending in `/v1` (e.g. `https://api.groq.com/openai/v1`, `http://localhost:11434/v1`), a model id, and a key if the server needs one |
| `anthropic-compatible` | any API that speaks the Anthropic Messages API (several model vendors offer one) | the base URL without `/v1` (requests go to `<base>/v1/messages`), a model id, a key. Add `-AuthHeader authorization` if it wants `Authorization: Bearer` instead of `x-api-key`. |

Pick a model that is good at **tool use**: the agent edits files and runs commands through
tools, and models that are weak at function calling will struggle.

## What gets installed

| Piece | Where | What it does |
|---|---|---|
| `deepseek-delegate` skill | `~\.claude\skills\deepseek-delegate\` | `SKILL.md` tells Claude when and how to delegate. `delegate.ps1` runs the agent and returns its result. `agent-settings.json` is the agent's own settings (gateway address and local gateway key). Available in every project. |
| LiteLLM gateway | `127.0.0.1:4000`, config `~\.litellm\litellm-config.yaml` (generated) | Serves the agent's requests and translates them for your provider. Serves only your chosen model. |
| Header filter | `127.0.0.1:4011`, `~\.litellm\gateway-filter.py` | Only for `opencode` and `anthropic-compatible`. Sits between LiteLLM and the provider, forwards only allowlisted headers, authenticates with your key, and rewrites a few request features third-party endpoints reject. |
| Start script | `~\.claude\start-litellm.ps1` | Starts the filter and gateway hidden if they aren't running. `delegate.ps1` calls it, so you never start anything by hand. |
| Provider record | `~\.litellm\provider.json` | Which provider and model you chose (no keys). |

## Requirements

- Windows 10/11, Windows PowerShell 5.1 (built in)
- Python 3.9+ from python.org (not the Microsoft Store stub)
- LiteLLM proxy: `python -m pip install "litellm[proxy]"` (setup offers to do this)
- Claude Code, native build (`claude.exe` in `%USERPROFILE%\.local\bin` or on PATH)
- An account with your chosen provider

## Install

Download or clone this repository, open PowerShell in its folder, and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
```

Setup asks which provider to use, asks for your key (hidden input), sends one real test
request to the provider before saving anything, stores the key as a user environment
variable (`OPENCODE_API_KEY`, `OPENROUTER_API_KEY` or `DELEGATE_API_KEY`), generates a
random `LITELLM_MASTER_KEY`, installs the files, and sends a test request through the gateway.

Non-interactive examples (run inside PowerShell):

```powershell
.\setup.ps1 -Provider opencode
.\setup.ps1 -Provider openrouter -Model deepseek/deepseek-chat
.\setup.ps1 -Provider openai-compatible -BaseUrl http://localhost:11434/v1 -Model qwen3-coder
.\setup.ps1 -Provider anthropic-compatible -BaseUrl https://api.example.com/anthropic -Model some-model
```

Other options: `-ExtraHeaders '{"X-Title":"my-app"}'` (extra request headers),
`-ApiKeyVar NAME` (use a key you already keep in another user variable), and
`-ContextTokens 128000` (the context window the agent assumes; default 200000, lower it
if your model's window is smaller). When calling through `powershell.exe -File`, escape
the quotes in JSON: `-ExtraHeaders '{\"X-Title\":\"my-app\"}'`.

To change provider or model later, re-run setup. It stops the running gateway and starts
it with the new configuration. Existing files are backed up as `*.bak-<timestamp>`.

## Use

In any Claude Code session, desktop or terminal: "delegate writing tests for utils.py to
DeepSeek", or "have the cheap model rename X across the repo". Claude writes a
self-contained prompt, runs the agent, and checks its work. The first delegation after a
reboot takes 10-15 s longer while the gateway starts.

## What leaves your machine

- **To your provider:** the delegated task and everything the agent reads or runs. Don't
  delegate work involving secrets.
- Your Claude login is never sent to the gateway or to the provider: the agent
  authenticates to the local gateway with the generated gateway key.

## Why the filter exists

For Anthropic-format providers, LiteLLM's Anthropic driver sends any `Authorization` token
it receives upstream **instead of** the key you configured. The filter drops every header
not on its allowlist and always sets your provider key itself, so a client token can never
reach the provider. **Don't point LiteLLM's `api_base` straight at an Anthropic-format
provider.** If the filter is down, those requests fail instead of going out unfiltered.

It also rewrites three things third-party endpoints tend to reject: mid-conversation
`system` messages, `redacted_thinking` blocks, and regex `pattern` rules in tool schemas
(the built-in Artifact tool has one).

OpenAI-format providers don't need it: LiteLLM uses your key and translates the request to
`chat/completions` (setup turns off LiteLLM's newer Responses API route, which most
gateways don't implement).

## Troubleshooting

- Logs: `%USERPROFILE%\.litellm\litellm-4000.log` and, for Anthropic-format providers,
  `gateway-filter.log` (provider errors with the request's shape, no message content).
- To save the full failing request for debugging (Anthropic-format providers), set the user
  variable `DELEGATE_FILTER_DUMP=1`, re-run the start script, and reproduce; it writes
  `last-failed-request.json` (includes the conversation) next to the filter.
- Restart everything: stop the `python.exe`/`litellm.exe` processes for ports 4000/4011,
  then run `~\.claude\start-litellm.ps1`.
- "unrecognized_model" notices on stderr are harmless.
- Tested: OpenCode Go through the filter, and the OpenAI-compatible and
  Anthropic-compatible routes (against OpenCode's OpenAI and Anthropic endpoints), each with
  real tool-using delegations. OpenRouter uses the same OpenAI-compatible route.

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1              # keep keys
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -RemoveKeys  # also remove them
```

Upgrading from an earlier version: re-run `setup.ps1`. It replaces the old
`opencode-filter.py`, and removes the terminal `claude` wrapper and opusplan settings file
that the first version installed.
