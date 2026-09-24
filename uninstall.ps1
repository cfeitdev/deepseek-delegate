<#
.SYNOPSIS
  Removes what setup.ps1 installed: stops the gateway and filter, deletes the skill,
  gateway files and logs, and takes the `claude` function out of your PowerShell profiles.
  Your keys stay in your user environment unless you pass -RemoveKeys.

    powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 [-RemoveKeys]
#>
param(
    [string]$InstallRoot = $env:USERPROFILE,
    [string[]]$ProfilePath,
    [switch]$RemoveKeys
)
$ErrorActionPreference = 'Stop'
$u8 = New-Object Text.UTF8Encoding $false
$claudeDir = Join-Path $InstallRoot '.claude'
$logDir    = Join-Path $InstallRoot '.litellm'
$filterPy  = Join-Path $logDir 'opencode-filter.py'
$config    = Join-Path $logDir 'litellm-config.yaml'

Write-Host '==> Stopping the gateway and filter started from this install'
Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='litellm.exe' OR Name='cmd.exe'" |
    Where-Object { $_.CommandLine -and ($_.CommandLine.Contains($filterPy) -or $_.CommandLine.Contains($config)) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "    stopped $($_.Name) $($_.ProcessId)" }

Write-Host '==> Removing files'
$targets = @(
    (Join-Path $claudeDir 'skills\deepseek-delegate'),
    (Join-Path $claudeDir 'start-litellm.ps1'),
    (Join-Path $claudeDir 'gateway-settings.json'),
    $filterPy, $config,
    (Join-Path $logDir 'opencode-filter.log'), (Join-Path $logDir 'opencode-filter.log.prev'),
    (Join-Path $logDir 'litellm-4000.log'), (Join-Path $logDir 'litellm-4000.log.prev'),
    (Join-Path $logDir 'last-failed-request.json')
)
foreach ($t in $targets) {
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force; Write-Host "    removed $t" }
}
if ((Test-Path $logDir) -and -not (Get-ChildItem $logDir -Force)) { Remove-Item -LiteralPath $logDir -Force }

Write-Host '==> Removing the `claude` function from PowerShell profiles'
if (-not $ProfilePath) {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $ProfilePath = @((Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
                     (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1'))
}
$block = '(?s)\r?\n?\r?\n?# >>> deepseek-delegate-kit: claude function >>>.*?# <<< deepseek-delegate-kit: claude function <<<\r?\n?'
foreach ($p in $ProfilePath) {
    if (-not (Test-Path $p)) { continue }
    $t = [IO.File]::ReadAllText($p)
    if ($t -match $block) {
        [IO.File]::WriteAllText($p, [regex]::Replace($t, $block, ''), $u8)
        Write-Host "    cleaned $p"
    }
}

if ($RemoveKeys) {
    Write-Host '==> Removing OPENCODE_API_KEY and LITELLM_MASTER_KEY from your user environment'
    [Environment]::SetEnvironmentVariable('OPENCODE_API_KEY', $null, 'User')
    [Environment]::SetEnvironmentVariable('LITELLM_MASTER_KEY', $null, 'User')
}
Write-Host '==> Done. Backups made by setup (*.bak-*) were left in place.'
