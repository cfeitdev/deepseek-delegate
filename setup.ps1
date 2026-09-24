<#
.SYNOPSIS
  Installs the deepseek-delegate skill and the local gateway it needs (LiteLLM on
  127.0.0.1:4000, plus a header filter on 127.0.0.1:4011 for Anthropic-compatible
  providers). Claude Code itself keeps its default settings; only the skill's agent
  uses the provider you choose here.

.DESCRIPTION
  Providers:
    opencode              OpenCode Go (Anthropic format). Default model deepseek-v4.1-flash.
    openrouter            OpenRouter. Pass -Model, e.g. "deepseek/deepseek-chat".
    openai-compatible     Any OpenAI-compatible API: pass -BaseUrl (ending in /v1) and -Model.
                          Groq, Together, Fireworks, DeepInfra, a local Ollama or LM Studio, ...
    anthropic-compatible  Any Anthropic-compatible API: pass -BaseUrl (without /v1) and -Model.

  Your API key is asked for once (hidden), checked with a real request, and stored as a
  user environment variable. A random local LITELLM_MASTER_KEY is generated. No key is
  ever written into the files this package ships.

  Run from the repository folder:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
  or non-interactively, for example:
    .\setup.ps1 -Provider openrouter -Model deepseek/deepseek-chat

.PARAMETER Provider      opencode | openrouter | openai-compatible | anthropic-compatible
.PARAMETER Model         Model id at the provider.
.PARAMETER BaseUrl       API base URL (openai-compatible: ends in /v1; anthropic-compatible: without /v1).
.PARAMETER AuthHeader    anthropic-compatible only: x-api-key (default) or authorization (Bearer).
.PARAMETER ExtraHeaders  JSON object of extra request headers, e.g. '{"HTTP-Referer":"https://example.com"}'.
.PARAMETER ApiKeyVar     User environment variable holding the key (defaults: OPENCODE_API_KEY,
                         OPENROUTER_API_KEY, or DELEGATE_API_KEY).
.PARAMETER ContextTokens Context window the agent assumes (default 200000). Set it to your model's
                         real window if that is smaller.
.PARAMETER InstallRoot   Where the files go (default: your user profile). Mainly for testing.
.PARAMETER SkipTest      Don't start the gateway and send the end-to-end test request.
#>
param(
    [ValidateSet('opencode', 'openrouter', 'openai-compatible', 'anthropic-compatible')][string]$Provider,
    [string]$Model,
    [string]$BaseUrl,
    [ValidateSet('x-api-key', 'authorization')][string]$AuthHeader = 'x-api-key',
    [string]$ExtraHeaders,
    [string]$ApiKeyVar,
    [int]$ContextTokens = 200000,
    [string]$InstallRoot = $env:USERPROFILE,
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

$claudeDir = Join-Path $InstallRoot '.claude'
$skillDir  = Join-Path $claudeDir 'skills\deepseek-delegate'
$logDir    = Join-Path $InstallRoot '.litellm'

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
if (-not $claudeExe) { Fail 'Claude Code (claude.exe) was not found. Install the native build from https://claude.com/claude-code, then re-run.' }
Ok "Claude Code: $claudeExe"

# ---------------------------------------------------------------- provider
Say 'Choosing the provider'
$previous = $null
$providerFile = Join-Path $logDir 'provider.json'
if (Test-Path $providerFile) { try { $previous = Get-Content -Raw $providerFile | ConvertFrom-Json } catch { } }

if (-not $Provider -and $previous) {
    $ans = Read-Host "Keep the current provider ($($previous.provider), model $($previous.model))? [Y/n]"
    if ($ans -notmatch '^(n|no)$') {
        $Provider = $previous.provider
        if (-not $Model) { $Model = $previous.model }
        if (-not $BaseUrl -and $previous.base_url) { $BaseUrl = $previous.base_url }
        if (-not $ApiKeyVar) { $ApiKeyVar = $previous.key_env }
        if (-not $PSBoundParameters.ContainsKey('AuthHeader') -and $previous.auth_header) { $AuthHeader = $previous.auth_header }
        if (-not $ExtraHeaders -and $previous.extra_headers) { $ExtraHeaders = ($previous.extra_headers | ConvertTo-Json -Compress) }
    }
}
if (-not $Provider) {
    Write-Host @"
    1) OpenCode Go            (DeepSeek V4.1 Flash; needs an OpenCode Go subscription)
    2) OpenRouter
    3) Other OpenAI-compatible API  (Groq, Together, Fireworks, DeepInfra, Ollama, LM Studio, ...)
    4) Other Anthropic-compatible API
"@
    $choice = Read-Host 'Provider [1]'
    $Provider = switch ($choice) { '2' { 'openrouter' } '3' { 'openai-compatible' } '4' { 'anthropic-compatible' } default { 'opencode' } }
}

$extra = [ordered]@{}
if ($ExtraHeaders) {
    try { ($ExtraHeaders | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $extra[$_.Name] = [string]$_.Value } }
    catch { Fail "-ExtraHeaders must be a JSON object, e.g. '{""X-Title"":""my-app""}'" }
}

switch ($Provider) {
    'opencode' {
        $type = 'anthropic'; if (-not $BaseUrl) { $BaseUrl = 'https://opencode.ai/zen/go' }
        if (-not $Model) { $Model = 'deepseek-v4.1-flash' }
        if (-not $ApiKeyVar) { $ApiKeyVar = 'OPENCODE_API_KEY' }
        $AuthHeader = 'x-api-key'
        if (-not $extra.Contains('x-opencode-session')) { $extra['x-opencode-session'] = 'deepseek-delegate' }  # OpenCode requires it
    }
    'openrouter' {
        $type = 'openai'; $BaseUrl = 'https://openrouter.ai/api/v1'
        if (-not $ApiKeyVar) { $ApiKeyVar = 'OPENROUTER_API_KEY' }
    }
    'openai-compatible' {
        $type = 'openai'
        if (-not $BaseUrl) { $BaseUrl = Read-Host 'Base URL, ending in /v1 (e.g. https://api.groq.com/openai/v1 or http://localhost:11434/v1)' }
        if (-not $ApiKeyVar) { $ApiKeyVar = 'DELEGATE_API_KEY' }
    }
    'anthropic-compatible' {
        $type = 'anthropic'
        if (-not $BaseUrl) { $BaseUrl = Read-Host 'Base URL, without /v1 (requests go to <base>/v1/messages)' }
        if (-not $ApiKeyVar) { $ApiKeyVar = 'DELEGATE_API_KEY' }
    }
}
if (-not $Model) { $Model = Read-Host "Model id at $Provider" }
if (-not $Model) { Fail 'A model id is required.' }
$BaseUrl = ([string]$BaseUrl).Trim().TrimEnd('/')
if (-not $BaseUrl) { Fail 'A base URL is required.' }
if ($type -eq 'anthropic' -and $BaseUrl -match '/v1$') { $BaseUrl = $BaseUrl -replace '/v1$', ''; Warn "dropped the trailing /v1 from the base URL (requests go to $BaseUrl/v1/messages)" }
Ok "provider=$Provider model=$Model base=$BaseUrl"

# ---------------------------------------------------------------- keys
Say 'Setting up keys'

function Test-ProviderKey([string]$key) {
    $h = @{}
    foreach ($k in $extra.Keys) { $h[$k] = $extra[$k] }
    if ($type -eq 'anthropic') {
        $url = "$BaseUrl/v1/messages"
        $h['anthropic-version'] = '2023-06-01'
        if ($AuthHeader -eq 'authorization') { $h['Authorization'] = "Bearer $key" } else { $h['x-api-key'] = $key }
    } else {
        $url = "$BaseUrl/chat/completions"
        if ($key) { $h['Authorization'] = "Bearer $key" }
    }
    $body = @{ model = $Model; max_tokens = 32; messages = @(@{ role = 'user'; content = 'Say ok' }) } | ConvertTo-Json -Depth 5 -Compress
    try {
        Invoke-RestMethod -Uri $url -Method Post -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 90 | Out-Null
        return 'ok'
    } catch {
        return "HTTP $($_.Exception.Response.StatusCode.value__) $($_.ErrorDetails.Message)".Trim()
    }
}

$apiKey = [Environment]::GetEnvironmentVariable($ApiKeyVar, 'User')
if ($apiKey) {
    Ok "using the $ApiKeyVar already in your user environment"
} else {
    $optional = $Provider -eq 'openai-compatible'
    $prompt = "Paste your $Provider API key (input is hidden)" + $(if ($optional) { '; press Enter if the server needs none' } else { '' })
    $sec = Read-Host $prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim() }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if (-not $apiKey -and -not $optional) { Fail 'No key entered.' }
}
$check = Test-ProviderKey $apiKey
if ($check -ne 'ok') { Fail "the provider rejected a test request for model '$Model' ($check). Check the key, model id and base URL." }
if ($apiKey) {
    [Environment]::SetEnvironmentVariable($ApiKeyVar, $apiKey, 'User')
    Ok "the key works with $Model; stored as user variable $ApiKeyVar"
} else {
    Ok "$Model answered without a key"
}

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
if ($apiKey) { Set-Item -Path "env:$ApiKeyVar" -Value $apiKey }
$env:LITELLM_MASTER_KEY = $masterKey

# ---------------------------------------------------------------- stop a running install
# A gateway that is already running keeps its old configuration, so stop the processes
# this install (or an earlier version of it) started before writing the new one.
$ours = @((Join-Path $logDir 'gateway-filter.py'), (Join-Path $logDir 'opencode-filter.py'), (Join-Path $logDir 'litellm-config.yaml'))
Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='litellm.exe' OR Name='cmd.exe'" |
    Where-Object { $cl = $_.CommandLine; $cl -and ($ours | Where-Object { $cl.Contains($_) }) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------- files
Say "Installing files under $InstallRoot"
$vars = [ordered]@{
    PYTHON_EXE     = $python
    LITELLM_EXE    = $litellm
    CLAUDE_EXE     = $claudeExe
    LOG_DIR        = $logDir
    FILTER_PY      = Join-Path $logDir 'gateway-filter.py'
    LITELLM_CONFIG = Join-Path $logDir 'litellm-config.yaml'
    START_SCRIPT   = Join-Path $claudeDir 'start-litellm.ps1'
    AGENT_SETTINGS = Join-Path $skillDir 'agent-settings.json'
    DELEGATE_PS1   = Join-Path $skillDir 'delegate.ps1'
    MASTER_KEY     = $masterKey
    CONTEXT_TOKENS = [string]$ContextTokens
}

function Backup($dest) { if (Test-Path $dest) { Copy-Item $dest "$dest.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force } }

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
    if ($t -match '\{\{[A-Z0-9_]+\}\}') { Fail "internal: unfilled placeholder $($Matches[0]) in $name" }
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
    Backup $dest
    [IO.File]::WriteAllText($dest, $t, $u8)
    Ok $dest
}

function Write-Generated($dest, $text) {
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
    Backup $dest
    [IO.File]::WriteAllText($dest, $text, $u8)
    Ok $dest
}

# YAML double-quoted scalar
function Q([string]$s) { '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"' }

# LiteLLM config: the provider's model under the names the agent can ask for.
if ($type -eq 'anthropic') {
    $params = @("model: $(Q "anthropic/$Model")", "api_base: $(Q 'http://127.0.0.1:4011')", "api_key: $(Q "os.environ/$ApiKeyVar")")
} else {
    # OpenRouter included: LiteLLM's generic OpenAI driver sends the model id unchanged
    # (e.g. "deepseek/deepseek-chat") and adds no provider-specific fields.
    $params = @("model: $(Q "openai/$Model")", "api_base: $(Q $BaseUrl)")
    $params += if ($apiKey) { "api_key: $(Q "os.environ/$ApiKeyVar")" } else { "api_key: $(Q 'none')" }
    if ($extra.Count) {
        $params += 'extra_headers:'
        foreach ($k in $extra.Keys) { $params += "  $(Q $k): $(Q $extra[$k])" }
    }
}
$yaml = @(
    '# Generated by deepseek-delegate setup.ps1. Re-run setup to change the provider.',
    "# Provider: $Provider, model: $Model",
    'model_list:'
)
foreach ($name in 'delegate-model', 'delegate-model[1m]', 'claude-opus-4-8', 'claude-opus-5') {
    $yaml += "  - model_name: $(Q $name)"
    $yaml += '    litellm_params:'
    $yaml += $params | ForEach-Object { "      $_" }
}
$yaml += @(
    '',
    'general_settings:',
    '  master_key: os.environ/LITELLM_MASTER_KEY',
    '',
    'litellm_settings:',
    '  # OpenAI-compatible providers: use chat/completions, not the newer Responses API,',
    '  # which most gateways (OpenRouter included) do not implement.',
    '  use_chat_completions_url_for_anthropic_messages: true',
    '  drop_params: true'
)
Write-Generated $vars.LITELLM_CONFIG (($yaml -join "`r`n") + "`r`n")

$providerInfo = [ordered]@{
    provider      = $Provider
    type          = $type
    model         = $Model
    base_url      = $BaseUrl
    key_env       = $ApiKeyVar
    auth_header   = $AuthHeader
    extra_headers = $extra
    uses_filter   = ($type -eq 'anthropic')
}
Write-Generated $providerFile (($providerInfo | ConvertTo-Json -Depth 5) + "`r`n")

if ($type -eq 'anthropic') {
    $filterCfg = [ordered]@{ upstream = $BaseUrl; auth_header = $AuthHeader; key_env = $ApiKeyVar; extra_headers = $extra }
    Write-Generated (Join-Path $logDir 'gateway-filter.json') (($filterCfg | ConvertTo-Json -Depth 5) + "`r`n")
    Install-File 'gateway-filter.py' $vars.FILTER_PY 'raw'
}
Install-File 'start-litellm.ps1'                   $vars.START_SCRIPT   'ps'
Install-File 'skill\agent-settings.template.json'  $vars.AGENT_SETTINGS 'json'
Install-File 'skill\delegate.ps1'                  $vars.DELEGATE_PS1   'ps'
Install-File 'skill\SKILL.md'                      (Join-Path $skillDir 'SKILL.md') 'raw'
try { [IO.File]::ReadAllText($vars.AGENT_SETTINGS) | ConvertFrom-Json | Out-Null }
catch { Fail "agent-settings.json is not valid JSON: $_" }
# agent-settings.json holds the local gateway key; setup's backups of it would too.
Get-ChildItem $skillDir -Filter 'agent-settings.json.bak-*' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }

# ---------------------------------------------------------------- earlier versions
foreach ($old in (Join-Path $claudeDir 'gateway-settings.json'), (Join-Path $logDir 'opencode-filter.py')) {
    if (Test-Path $old) { Remove-Item -LiteralPath $old -Force; Ok "removed old $old" }
}
if ($type -ne 'anthropic') {
    foreach ($old in (Join-Path $logDir 'gateway-filter.py'), (Join-Path $logDir 'gateway-filter.json')) {
        if (Test-Path $old) { Remove-Item -LiteralPath $old -Force; Ok "removed $old (not used by $Provider)" }
    }
}
$docs = [Environment]::GetFolderPath('MyDocuments')
$block = '(?s)\r?\n?\r?\n?# >>> deepseek-delegate-kit: claude function >>>.*?# <<< deepseek-delegate-kit: claude function <<<\r?\n?'
foreach ($p in (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'), (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1')) {
    if ((Test-Path $p) -and ([IO.File]::ReadAllText($p) -match $block)) {
        [IO.File]::WriteAllText($p, [regex]::Replace([IO.File]::ReadAllText($p), $block, ''), $u8)
        Ok "removed the old claude function from $p"
    }
}

# ---------------------------------------------------------------- test
if (-not $SkipTest) {
    Say 'Starting the gateway and sending a test request'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $vars.START_SCRIPT
    if ($out) { Warn $out }
    $urls = @('http://127.0.0.1:4000/health/liveliness')
    if ($type -eq 'anthropic') { $urls += 'http://127.0.0.1:4011/health' }
    foreach ($u in $urls) {
        try { Invoke-RestMethod $u -TimeoutSec 5 | Out-Null } catch { Fail "$u is not answering; see the logs in $logDir" }
    }
    # Authenticate the way the agent does (gateway key as the bearer token).
    $h = @{ 'Authorization' = "Bearer $masterKey"; 'anthropic-version' = '2023-06-01' }
    $body = '{"model":"delegate-model","max_tokens":200,"messages":[{"role":"user","content":"Reply with just: ok"}]}'
    try {
        $r = Invoke-RestMethod -Uri 'http://127.0.0.1:4000/v1/messages' -Method Post -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 120
        Ok "$Model answered through the gateway: $(($r.content | Where-Object type -eq 'text').text)"
    } catch {
        Fail "test request failed: HTTP $($_.Exception.Response.StatusCode.value__) $($_.ErrorDetails.Message). If port 4000 or 4011 was already taken by something else, stop it and re-run."
    }
}

Say 'Done'
Write-Host @"
  - Start a new Claude Code session (desktop or terminal) and ask it to delegate
    something, e.g. "delegate writing tests for utils.py to DeepSeek".
  - Change provider or model later: re-run setup.ps1.
  - Logs: $logDir
  - Remove everything: powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
"@
