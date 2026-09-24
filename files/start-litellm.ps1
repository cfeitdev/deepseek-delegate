# Starts the local LiteLLM gateway (127.0.0.1:4000) and the OpenCode header filter
# (127.0.0.1:4011) if they aren't already running. Called by the deepseek-delegate
# skill's delegate.ps1. If the filter is down, DeepSeek requests fail closed
# (connection refused) instead of reaching OpenCode unfiltered.
param([int]$port = 4000, [int]$filterPort = 4011)
$ErrorActionPreference = 'SilentlyContinue'
$python = '{{PYTHON_EXE}}'
$exe    = '{{LITELLM_EXE}}'
$config = '{{LITELLM_CONFIG}}'
$logDir = '{{LOG_DIR}}'
$filter = '{{FILTER_PY}}'

function Test-Url($url) {
    try { Invoke-RestMethod $url -TimeoutSec 2 | Out-Null; $true } catch { $false }
}

# Launch through WMI so the process is not tied to the caller's process tree and keeps
# running after the hook exits. The keys come from the user-level environment.
function Start-Hidden($cmd) {
    $si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
    Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $cmd; CurrentDirectory = $env:USERPROFILE; ProcessStartupInformation = $si
    } | Out-Null
}

function Wait-Url($url) {
    for ($i = 0; $i -lt 45; $i++) { if (Test-Url $url) { return $true }; Start-Sleep -Seconds 1 }
    $false
}

New-Item -ItemType Directory -Force $logDir | Out-Null
$problems = @()

$filterUrl = "http://127.0.0.1:$filterPort/health"
if (-not (Test-Url $filterUrl)) {
    $flog = "$logDir\opencode-filter.log"
    if (Test-Path $flog) { Move-Item $flog "$flog.prev" -Force }
    Start-Hidden "cmd.exe /c `"`"$python`" `"$filter`" $filterPort > `"$flog`" 2>&1`""
    if (-not (Wait-Url $filterUrl)) { $problems += "OpenCode filter did not start on port $filterPort (see $flog)" }
}

$gatewayUrl = "http://127.0.0.1:$port/health/liveliness"
if (-not (Test-Url $gatewayUrl)) {
    $log = "$logDir\litellm-$port.log"
    if (Test-Path $log) { Move-Item $log "$log.prev" -Force }
    # PYTHONIOENCODING: LiteLLM's banner crashes on cp1252 when stdout is redirected to a file.
    Start-Hidden "cmd.exe /c `"set PYTHONIOENCODING=utf-8&& `"$exe`" --config `"$config`" --host 127.0.0.1 --port $port > `"$log`" 2>&1`""
    if (-not (Wait-Url $gatewayUrl)) { $problems += "LiteLLM gateway did not start on port $port (see $log)" }
}

if ($problems) {
    Write-Output ('{"systemMessage": "' + (($problems -join '; ') -replace '\\','\\') + '"}')
}
exit 0
