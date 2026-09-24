# Runs one task on a headless Claude Code agent backed by deepseek-v4.1-flash
# (local LiteLLM gateway -> opencode-filter.py -> OpenCode) and prints its result.
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
# Settings for the delegated agent only: gateway URL, gateway key, every model slot on DeepSeek.
$settings    = Join-Path $PSScriptRoot 'agent-settings.json'
$startScript = '{{START_SCRIPT}}'
$logDir      = '{{LOG_DIR}}'
$model       = 'deepseek-v4.1-flash'

if (-not (Test-Path $PromptFile)) { Write-Output "delegate: prompt file not found: $PromptFile"; exit 2 }
if (-not (Test-Path $WorkDir))    { Write-Output "delegate: work dir not found: $WorkDir"; exit 2 }

# Desktop sessions export ANTHROPIC_BASE_URL=https://api.anthropic.com and other session
# variables, which would override the gateway settings. Clear them for this process only.
Get-ChildItem env: | Where-Object { $_.Name -match '^(ANTHROPIC|CLAUDE_CODE)' } |
    ForEach-Object { [Environment]::SetEnvironmentVariable($_.Name, $null, 'Process') }

# Make sure the gateway and the OpenCode header filter are running.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startScript | Out-Null
foreach ($url in 'http://127.0.0.1:4011/health', 'http://127.0.0.1:4000/health/liveliness') {
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
$offModel = $models | Where-Object { $_ -notlike 'deepseek*' -and $_ -notin 'claude-opus-4-8', 'claude-opus-5' }
$status = if ($r.is_error) { 'ERROR' } else { 'ok' }
Write-Output ("[deepseek agent] status={0} turns={1} time={2}s models={3} session={4}" -f `
    $status, $r.num_turns, [math]::Round($r.duration_ms / 1000), ($models -join ','), $r.session_id)
if ($offModel) { Write-Output "[deepseek agent] WARNING: some steps ran on $($offModel -join ', '), not DeepSeek." }
Write-Output ''
Write-Output $r.result
if ($r.is_error) { exit 1 }
