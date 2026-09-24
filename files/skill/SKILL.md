---
name: deepseek-delegate
description: Hand a self-contained task to a separate Claude Code agent running on DeepSeek V4.1 Flash (via the local LiteLLM gateway and OpenCode) instead of doing it yourself, and collect its result. Use when the user asks to delegate, offload, or send work to DeepSeek / "the DeepSeek agent" / "flash", or to save their Claude usage on bulk, mechanical, or low-risk work (boilerplate, repetitive edits, first-pass research in the codebase, running and summarizing commands).
---

# Delegate a task to the DeepSeek agent

`delegate.ps1` (next to this file) starts a headless Claude Code agent whose model is
`deepseek-v4.1-flash`. It runs through the user's local gateway (127.0.0.1:4000) and
`opencode-filter.py` (127.0.0.1:4011), which keeps the user's Anthropic login away from
OpenCode. The agent has the normal Claude Code tools and runs in auto mode in the working
directory you give it, so it can read, edit, and run commands there.

## When to delegate

Good fits: well-specified, checkable work, such as boilerplate, repetitive edits across files,
generating tests or docs from existing code, searching a codebase and summarizing, running a
command and reporting results.

Keep it yourself: ambiguous design decisions, security-sensitive changes, anything involving
secrets or credentials (the task and any files the agent reads are sent to OpenCode), and
tasks where checking the result would cost more than doing it.

## How to delegate

1. Write the task to a prompt file in your scratchpad (or `%TEMP%`). The agent has none of
   this conversation's context, so the prompt must stand alone:
   - the goal, and the absolute paths of the relevant files and directories
   - constraints (what not to touch, style to follow)
   - what "done" means, and what to put in its final reply (for example: list of files
     changed and a one-paragraph summary)
2. Run it with the PowerShell tool:

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "{{DELEGATE_PS1}}" -PromptFile "<prompt file>" -WorkDir "<absolute project dir>"
   ```

   Options: `-PermissionMode acceptEdits` (file edits only, no command classifier) or
   `plan` (read-only, returns a plan). The default is `auto`.
   Small tasks finish in under a minute. For anything longer, set `run_in_background: true`
   and wait for the completion notification instead of polling.
3. Read the output. The first line is a status line: `status`, `turns`, `time`, `models`
   used, and the agent's `session` id. The agent's final reply follows it.
4. Verify before reporting success: read the changed files, run the tests, or diff. Treat
   the agent's summary as a claim to check, not as a fact. If the status line has a
   WARNING that steps ran on a non-DeepSeek model, tell the user.

Several independent tasks can run in parallel as separate background calls, as long as
they don't edit the same files.

## Exit codes

- 0: finished. 1: the agent reported an error (its message is printed).
- 2: bad prompt file or work dir. 3: gateway or filter not running (logs in
  `{{LOG_DIR}}`). 4: the agent produced no result (stderr is printed).

If the gateway won't start, tell the user instead of falling back to doing the work
silently.
