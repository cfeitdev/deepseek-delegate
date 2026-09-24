# >>> deepseek-delegate-kit: claude function >>>
# Terminal `claude` runs through the local LiteLLM gateway (opusplan: Opus on your Claude
# subscription, execution on DeepSeek via OpenCode). The Claude desktop app launches its
# own claude.exe, so it never sees this. Bypass for one run with:  claude.exe ...
function claude {
    $exe = '{{CLAUDE_EXE}}'
    $subcommands = 'agents','attach','auth','auto-mode','doctor','gateway','import','install',
                   'logs','mcp','plugin','plugins','project','respawn','rm','setup-token',
                   'ultrareview','update','config','migrate-installer'
    if ($args.Count -gt 0 -and $subcommands -contains $args[0]) {
        & $exe @args
    } else {
        & $exe --settings '{{GATEWAY_SETTINGS}}' @args
    }
}
# <<< deepseek-delegate-kit: claude function <<<
