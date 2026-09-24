<#
.SYNOPSIS
  Installs the deepseek-delegate skill and the local gateway it needs:
  LiteLLM on 127.0.0.1:4000, opencode-filter.py on 127.0.0.1:4011, a gateway
  settings file for terminal `claude`, and a `claude` function for PowerShell.

.DESCRIPTION
  Uses YOUR OpenCode API key (asked for once, checked, then stored as the user
  environment variable OPENCODE_API_KEY) and generates a random local
  LITELLM_MASTER_KEY. No key is ever written into the files this package ships.

  Run from the unzipped folder:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1

.PARAMETER InstallRoot
  Where the files go (default: your user profile). Mainly for testing.
.PARAMETER ProfilePath
  PowerShell profile(s) to add the `claude` function to. Default: the Windows
  PowerShell 5.1 profile, plus the PowerShell 7 profile if pwsh is installed.
.PARAMETER SkipProfile
  Don't touch any PowerShell profile.
.PARAMETER SkipTest
  Don't start the gateway and send the end-to-end test request.
#>
param(
    [string]$InstallRoot = $env:USERPROFILE,
    [string[]]$ProfilePath,
    [switch]$SkipProfile,
    [switch]$SkipTest
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $here 'files'
$u8   = New-Object Text.UTF8Encoding $false

function Say($m)  { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    ok: $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    warning: $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- prerequisites
Say 'Checking prerequisites'

# Runs a native program and returns its stdout lines. Windows PowerShell 5.1 turns any
# native stderr output into a terminating error under 'Stop', so relax it for the call.
function Invoke-Native([string]$exe, [string[]]$arguments) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& $exe @arguments 2>$null); $script:nativeExit = $LASTEXITCODE }
    catch { $out = @(); $script:nativeExit = 1 }
    finally { $ErrorActionPreference = $old }
    return $out
}

# Every python.org Python the `py` launcher knows about, then `python` on PATH.
function Get-PythonCandidates {
    $list = @()
    if (Get-Command py -CommandType Application -ErrorAction SilentlyContinue) {
        foreach ($line in (Invoke-Native 'py' @('-0p'))) {
            $m = [regex]::Match([string]$line, '([A-Za-z]:\\.*python\.exe)\s*$')
            if ($m.Success) { $list += $m.Groups[1].Value }
        }
    }
    $list += @(Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
    $list | Where-Object { $_ -and $_ -notmatch 'WindowsApps' -and (Test-Path $_) } | Select-Object -Unique
}

function Test-Python([string]$py, [string]$code) {
    Invoke-Native $py @('-c', $code) | Out-Null
    return ($script:nativeExit -eq 0)
}

function Find-LiteLLMExe([string]$py) {
    $dirs = Invoke-Native $py @('-c', "import os, sysconfig; print(sysconfig.get_path('scripts')); print(sysconfig.get_path('scripts', os.name + '_user'))")
    foreach ($d in $dirs) { $p = Join-Path ([string]$d).Trim() 'litellm.exe'; if (Test-Path $p) { return $p } }
}

$candidates = @(Get-PythonCandidates | Where-Object { Test-Python $_ 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' })
if (-not $candidates) { Fail 'Python 3.9 or later from python.org is required (the Microsoft Store stub does not work). Install it, then re-run.' }

# Prefer a Python that already has the LiteLLM proxy installed.
$python = $null; $litellm = $null
foreach ($c in $candidates) {
    if (Test-Python $c 'import litellm, fastapi, uvicorn') {
        $exe = Find-LiteLLMExe $c
        if ($exe) { $python = $c; $litellm = $exe; break }
    }
}
if (-not $python) { $python = $candidates[0] }
Ok "Python: $python"
if (-not $litellm) {
    $ans = Read-Host "LiteLLM proxy is not installed for $python. Install it now with pip (litellm[proxy])? [y/N]"
    if ($ans -notmatch '^(y|yes)$') { Fail 'LiteLLM is required. Install it with:  python -m pip install "litellm[proxy]"' }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $python -m pip install --upgrade 'litellm[proxy]'
    $pipExit = $LASTEXITCODE; $ErrorActionPreference = $old
    if ($pipExit -ne 0) { Fail 'pip install failed; see the output above.' }
    $litellm = Find-LiteLLMExe $python
    if (-not $litellm) { Fail 'LiteLLM installed but litellm.exe was not found in the Python scripts folders.' }
}
Ok "LiteLLM: $litellm"

$claudeExe = @("$env:USERPROFILE\.local\bin\claude.exe") +
             @(Get-Command claude.exe -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object { $_.Source }) |
             Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $claudeExe) { Fail 'Claude Code (claude.exe) was not found. Install the native build from https://claude.com/claude-code and sign in once, then re-run.' }
Ok "Claude Code: $claudeExe"

# ---------------------------------------------------------------- keys
Say 'Setting up keys'

function Test-OpenCodeKey($key) {
    $body = '{"model":"deepseek-v4.1-flash","max_tokens":16,"messages":[{"role":"user","content":"Say ok"}]}'
    $h = @{ 'x-api-key' = $key; 'anthropic-version' = '2023-06-01'; 'x-opencode-session' = 'deepseek-delegate-setup' }
    try {
        Invoke-RestMethod -Uri 'https://opencode.ai/zen/go/v1/messages' -Method Post -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 60 | Out-Null
        return 'ok'
    } catch {
        return "HTTP $($_.Exception.Response.StatusCode.value__) $($_.ErrorDetails.Message)"
    }
}

$ocKey = [Environment]::GetEnvironmentVariable('OPENCODE_API_KEY', 'User')
if ($ocKey) {
    Ok 'using the OPENCODE_API_KEY already in your user environment'
} else {
    $sec = Read-Host 'Paste your OpenCode API key (input is hidden)' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $ocKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim() }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if (-not $ocKey) { Fail 'No key entered.' }
}
$check = Test-OpenCodeKey $ocKey
if ($check -ne 'ok') { Fail "OpenCode rejected the key for deepseek-v4.1-flash on the Go plan ($check). Check the key and that your account has OpenCode Go." }
[Environment]::SetEnvironmentVariable('OPENCODE_API_KEY', $ocKey, 'User')
Ok 'OpenCode key works with deepseek-v4.1-flash; stored as user variable OPENCODE_API_KEY'

$masterKey = [Environment]::GetEnvironmentVariable('LITELLM_MASTER_KEY', 'User')
if ($masterKey) {
    Ok 'using the LITELLM_MASTER_KEY already in your user environment'
} else {
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $masterKey = 'sk-local-' + (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    [Environment]::SetEnvironmentVariable('LITELLM_MASTER_KEY', $masterKey, 'User')
    Ok 'generated a random local LITELLM_MASTER_KEY (user variable)'
}
$env:OPENCODE_API_KEY = $ocKey
$env:LITELLM_MASTER_KEY = $masterKey

# ---------------------------------------------------------------- files
Say "Installing files under $InstallRoot"
$claudeDir   = Join-Path $InstallRoot '.claude'
$skillDir    = Join-Path $claudeDir 'skills\deepseek-delegate'
$logDir      = Join-Path $InstallRoot '.litellm'
$vars = [ordered]@{
    PYTHON_EXE       = $python
    LITELLM_EXE      = $litellm
    CLAUDE_EXE       = $claudeExe
    LOG_DIR          = $logDir
    FILTER_PY        = Join-Path $logDir 'opencode-filter.py'
    LITELLM_CONFIG   = Join-Path $logDir 'litellm-config.yaml'
    START_SCRIPT     = Join-Path $claudeDir 'start-litellm.ps1'
    GATEWAY_SETTINGS = Join-Path $claudeDir 'gateway-settings.json'
    DELEGATE_PS1     = Join-Path $skillDir 'delegate.ps1'
    MASTER_KEY       = $masterKey
}

function Install-File($name, $dest, $kind) {
    $t = [IO.File]::ReadAllText((Join-Path $src $name))
    foreach ($k in $vars.Keys) {
        $v = [string]$vars[$k]
        switch ($kind) {
            'ps'   { $v = $v.Replace("'", "''") }                       # inside '...' in PowerShell
            'json' { $v = $v.Replace('\', '/').Replace('"', '\"') }     # JSON string, forward slashes
        }
        $t = $t.Replace("{{$k}}", $v)
    }
    if ($t -match '\{\{[A-Z_]+\}\}') { Fail "internal: unfilled placeholder $($Matches[0]) in $name" }
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
    if (Test-Path $dest) { Copy-Item $dest "$dest.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force }
    [IO.File]::WriteAllText($dest, $t, $u8)
    Ok $dest
}

Install-File 'opencode-filter.py'             $vars.FILTER_PY        'raw'
Install-File 'litellm-config.yaml'            $vars.LITELLM_CONFIG   'raw'
Install-File 'start-litellm.ps1'              $vars.START_SCRIPT     'ps'
Install-File 'gateway-settings.template.json' $vars.GATEWAY_SETTINGS 'json'
Install-File 'skill\delegate.ps1'             $vars.DELEGATE_PS1     'ps'
Install-File 'skill\SKILL.md'                 (Join-Path $skillDir 'SKILL.md') 'raw'
try { [IO.File]::ReadAllText($vars.GATEWAY_SETTINGS) | ConvertFrom-Json | Out-Null }
catch { Fail "gateway-settings.json is not valid JSON: $_" }

# ---------------------------------------------------------------- profile
if (-not $SkipProfile) {
    Say 'Adding the `claude` function to your PowerShell profile(s)'
    if (-not $ProfilePath) {
        $docs = [Environment]::GetFolderPath('MyDocuments')
        $ProfilePath = @(Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1')
        if (Get-Command pwsh -ErrorAction SilentlyContinue) { $ProfilePath += Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1' }
    }
    $snippet = [IO.File]::ReadAllText((Join-Path $src 'profile-snippet.ps1'))
    foreach ($k in 'CLAUDE_EXE', 'GATEWAY_SETTINGS') { $snippet = $snippet.Replace("{{$k}}", ([string]$vars[$k]).Replace("'", "''")) }
    $block = '(?s)# >>> deepseek-delegate-kit: claude function >>>.*?# <<< deepseek-delegate-kit: claude function <<<\r?\n?'
    foreach ($p in $ProfilePath) {
        New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
        $existing = if (Test-Path $p) { [IO.File]::ReadAllText($p) } else { '' }
        if ($existing) { Copy-Item $p "$p.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force }
        if ($existing -match $block) { $new = [regex]::Replace($existing, $block, { param($m) $snippet }) }
        else { $new = $existing.TrimEnd() + $(if ($existing) { "`r`n`r`n" } else { '' }) + $snippet }
        [IO.File]::WriteAllText($p, $new, $u8)
        Ok $p
    }
    $policy = Get-ExecutionPolicy
    if ($policy -in 'Restricted', 'AllSigned') {
        Warn "your PowerShell execution policy is '$policy', so profiles don't load. To allow them for your user only: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
    }
}

# ---------------------------------------------------------------- test
if (-not $SkipTest) {
    Say 'Starting the gateway and sending a test request'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $vars.START_SCRIPT
    if ($out) { Warn $out }
    foreach ($u in 'http://127.0.0.1:4011/health', 'http://127.0.0.1:4000/health/liveliness') {
        try { Invoke-RestMethod $u -TimeoutSec 5 | Out-Null } catch { Fail "$u is not answering; see the logs in $logDir" }
    }
    # A fake Claude login header proves the filter, not the login, authenticates to OpenCode.
    $h = @{ 'x-litellm-api-key' = "Bearer $masterKey"; 'anthropic-version' = '2023-06-01'; 'Authorization' = 'Bearer sk-ant-oat01-SETUP-TEST' }
    $body = '{"model":"deepseek-v4.1-flash","max_tokens":200,"messages":[{"role":"user","content":"Reply with just: ok"}]}'
    try {
        $r = Invoke-RestMethod -Uri 'http://127.0.0.1:4000/v1/messages' -Method Post -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 90
        Ok "DeepSeek answered through gateway and filter: $(($r.content | Where-Object type -eq 'text').text)"
    } catch {
        Fail "test request failed: HTTP $($_.Exception.Response.StatusCode.value__) $($_.ErrorDetails.Message). If port 4000 or 4011 was already taken by something else, stop it and re-run."
    }
}

Say 'Done'
Write-Host @"
  - Desktop app: start a new session and ask it to delegate something to DeepSeek.
  - Terminal: open a NEW PowerShell window and run `claude` (opusplan through the gateway).
  - Logs: $logDir
  - Remove everything: powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
"@
