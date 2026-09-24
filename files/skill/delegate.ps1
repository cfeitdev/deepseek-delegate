# Runs one task on a headless Claude Code agent backed by the delegate model chosen at
# setup (DeepSeek V4.1 Flash on OpenCode Go by default; any provider LiteLLM can reach)
# and prints its result. Route: local LiteLLM gateway -> [header filter] -> provider.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File delegate.ps1 -PromptFile task.md [-WorkDir C:\proj] [-PermissionMode auto]
#
# The prompt is read from a file to avoid shell quoting problems.
param(
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [string]$WorkDir = (Get-Location).Path,
    [ValidateSet('auto', 'acceptEdits', 'default', 'plan')][string]$PermissionMode = 'auto'
)
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object Text.UTF8Encoding $false
[Console]::OutputEncoding = $OutputEncoding

$exe         = '{{CLAUDE_EXE}}'
$startScript = '{{START_SCRIPT}}'
$logDir      = '{{LOG_DIR}}'
# Settings for the delegated agent only: gateway URL, gateway key, every model slot on the delegate model.
$settings    = Join-Path $PSScriptRoot 'agent-settings.json'
# The gateway serves the chosen provider's model under these names; nothing else.
$model       = 'delegate-model'
$ourModels   = 'delegate-model', 'delegate-model[1m]', 'claude-opus-4-8', 'claude-opus-5'
$provider    = Get-Content -Raw (Join-Path $logDir 'provider.json') | ConvertFrom-Json

if (-not (Test-Path $PromptFile)) { Write-Output "delegate: prompt file not found: $PromptFile"; exit 2 }
if (-not (Test-Path $WorkDir))    { Write-Output "delegate: work dir not found: $WorkDir"; exit 2 }

# Desktop sessions export ANTHROPIC_BASE_URL=https://api.anthropic.com and other session
# variables, which would override the agent settings. Clear them for this process only.
Get-ChildItem env: | Where-Object { $_.Name -match '^(ANTHROPIC|CLAUDE_CODE)' } |
    ForEach-Object { [Environment]::SetEnvironmentVariable($_.Name, $null, 'Process') }

# Make sure the gateway (and the header filter, if this provider uses it) is running.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startScript | Out-Null
$urls = @('http://127.0.0.1:4000/health/liveliness')
if ($provider.uses_filter) { $urls += 'http://127.0.0.1:4011/health' }
foreach ($url in $urls) {
    try { Invoke-RestMethod $url -TimeoutSec 3 | Out-Null }
    catch { Write-Output "delegate: $url is not answering; see $logDir"; exit 3 }
}

$errFile = [IO.Path]::GetTempFileName()
Push-Location $WorkDir
# PowerShell 5.1 turns any native stderr line into an error record; with 'Stop' the
# agent's harmless unknown-model warning would abort the script.
$ErrorActionPreference = 'Continue'
try {
    $raw = Get-Content -Raw -Encoding UTF8 $PromptFile |
        & $exe --settings $settings -p --model $model --permission-mode $PermissionMode --output-format json 2> $errFile
} finally {
    Pop-Location
}

try {
    $r = ($raw -join "`n") | ConvertFrom-Json
} catch {
    Write-Output "delegate: agent produced no JSON result. stderr:"
    Get-Content $errFile | Where-Object { $_ -notmatch 'unrecognized_model|model catalog|auto-compact keeps|CLAUDE_CODE_DISABLE_UNKNOWN' } | Select-Object -Last 20
    Remove-Item -LiteralPath $errFile -Force
    exit 4
}
Remove-Item -LiteralPath $errFile -Force

$models = @()
if ($r.modelUsage) { $models = @($r.modelUsage.PSObject.Properties.Name) }
$offModel = $models | Where-Object { $_ -notin $ourModels }
$status = if ($r.is_error) { 'ERROR' } else { 'ok' }
Write-Output ("[delegate agent] status={0} provider={1} model={2} turns={3} time={4}s session={5}" -f `
    $status, $provider.provider, $provider.model, $r.num_turns, [math]::Round($r.duration_ms / 1000), $r.session_id)
if ($offModel) { Write-Output "[delegate agent] WARNING: some steps asked for $($offModel -join ', '), which the gateway does not serve." }
Write-Output ''
Write-Output $r.result
if ($r.is_error) { exit 1 }
