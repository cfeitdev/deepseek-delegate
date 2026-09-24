<#
.SYNOPSIS
  Removes what setup.ps1 installed: stops the gateway and filter and deletes the skill,
  gateway files and logs. Also cleans up the terminal `claude` wrapper and opusplan
  settings file that earlier versions of this package installed.
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
$provider  = $null
try { $provider = Get-Content -Raw (Join-Path $logDir 'provider.json') | ConvertFrom-Json } catch { }

Write-Host '==> Stopping the gateway and filter started from this install'
$ours = @((Join-Path $logDir 'gateway-filter.py'), (Join-Path $logDir 'opencode-filter.py'), (Join-Path $logDir 'litellm-config.yaml'))
Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='litellm.exe' OR Name='cmd.exe'" |
    Where-Object { $cl = $_.CommandLine; $cl -and ($ours | Where-Object { $cl.Contains($_) }) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "    stopped $($_.Name) $($_.ProcessId)" }

Write-Host '==> Removing files'
$targets = @(
    (Join-Path $claudeDir 'skills\deepseek-delegate'),
    (Join-Path $claudeDir 'start-litellm.ps1'),
    (Join-Path $claudeDir 'gateway-settings.json')
)
foreach ($n in 'gateway-filter.py', 'gateway-filter.json', 'opencode-filter.py', 'litellm-config.yaml', 'provider.json',
               'gateway-filter.log', 'gateway-filter.log.prev', 'opencode-filter.log', 'opencode-filter.log.prev',
               'litellm-4000.log', 'litellm-4000.log.prev', 'last-failed-request.json') {
    $targets += Join-Path $logDir $n
}
foreach ($t in $targets) {
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force; Write-Host "    removed $t" }
}
if ((Test-Path $logDir) -and -not (Get-ChildItem $logDir -Force)) { Remove-Item -LiteralPath $logDir -Force }

Write-Host '==> Removing any `claude` function an earlier version added to PowerShell profiles'
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
    $vars = @('LITELLM_MASTER_KEY')
    if ($provider -and $provider.key_env) { $vars += $provider.key_env } else { $vars += 'OPENCODE_API_KEY' }
    Write-Host "==> Removing $($vars -join ' and ') from your user environment"
    foreach ($v in $vars) { [Environment]::SetEnvironmentVariable($v, $null, 'User') }
}
Write-Host '==> Done. Backups made by setup (*.bak-*) were left in place.'
