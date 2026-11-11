<#
.SYNOPSIS
    OPTIONAL: a token-protected HTTP endpoint so a *tailnet* peer can drive this
    PC directly, instead of going through the GitHub mailbox.

.DESCRIPTION
    Read docs/agent-bridge.fa.md first.  Important: the Arena sandbox cannot
    reach a tailnet (its egress allowlist blocks controlplane.tailscale.com and
    100.64.0.0/10), so this endpoint is for YOUR other devices and for the
    "phase 2" setup, not for the built-in agent.  The GitHub mailbox remains the
    transport that works today.

    The listener binds to 127.0.0.1 only; publish it to the tailnet with:
        tailscale serve --bg 8765
    which gives you https://<machine>.<tailnet>.ts.net/ with a real certificate,
    reachable only from devices in your tailnet.

.EXAMPLE
    .\Live-Service.ps1 -Install          # token + scheduled task + start
    .\Live-Service.ps1                    # run in the foreground
    curl -H "Authorization: Bearer <token>" http://127.0.0.1:8765/health
#>

[CmdletBinding()]
param(
    [int]$Port = 8765,
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'win-agent\agent.config.json'),
    [string]$TokenFile = (Join-Path $env:LOCALAPPDATA 'win-agent\live-token.txt'),
    [switch]$Install,
    [switch]$ShowToken
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AgentTask.ps1')

$cfg = Get-AgentConfig -Path $ConfigPath
$prefix = "http://127.0.0.1:$Port/"

if ($Install) {
    if (-not (Test-Path -LiteralPath $TokenFile)) {
        New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($TokenFile)) | Out-Null
        $bytes = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($bytes)
        [System.IO.File]::WriteAllText($TokenFile, [System.Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_').TrimEnd('='))
        try { icacls $TokenFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null } catch { }
    }
    $launcher = Join-Path $env:LOCALAPPDATA 'win-agent\run-live.cmd'
    $line = '@echo off' + "`r`n" + ('powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Port {1}' -f $PSCommandPath, $Port) + "`r`n"
    [System.IO.File]::WriteAllText($launcher, $line, (New-Object System.Text.ASCIIEncoding))
    & schtasks.exe /Create /TN 'LocalAccessLiveService' /TR "`"$launcher`"" /SC ONLOGON /RL LIMITED /F *> $null
    Start-Process -FilePath $launcher -WindowStyle Hidden
    Write-Host "installed. token: $(Get-Content -LiteralPath $TokenFile -Raw)" -ForegroundColor Green
    Write-Host "publish it on the tailnet with:  tailscale serve --bg $Port"
    return
}

if ($ShowToken) { Get-Content -LiteralPath $TokenFile -Raw; return }
if (-not (Test-Path -LiteralPath $TokenFile)) { throw "no token file; run with -Install first ($TokenFile)" }
$expected = (Get-Content -LiteralPath $TokenFile -Raw).Trim()

function Send-Json {
    param($Context, [int]$Status, [string]$Json)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "listening on $prefix  (Ctrl+C to stop)" -ForegroundColor Green

while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
        $request = $context.Request
        $path = $request.Url.AbsolutePath

        if ($path -eq '/health') {
            Send-Json -Context $context -Status 200 -Json (@{
                ok = $true; host = $env:COMPUTERNAME; worker = $script:AgentWorkerVersion
            } | ConvertTo-Json -Compress)
            continue
        }

        if ($path -ne '/task') { Send-Json -Context $context -Status 404 -Json '{"ok":false,"error":"use /task"}'; continue }
        if ($request.HttpMethod -ne 'POST') { Send-Json -Context $context -Status 405 -Json '{"ok":false,"error":"POST only"}'; continue }

        $auth = [string]$request.Headers['Authorization']
        if ($auth -ne "Bearer $expected") { Send-Json -Context $context -Status 401 -Json '{"ok":false,"error":"bad token"}'; continue }

        $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
        $body = $reader.ReadToEnd()
        $reader.Close()
        $req = $body | ConvertFrom-Json
        if (-not $req.req) { $req | Add-Member -NotePropertyName req -NotePropertyValue ([Guid]::NewGuid().ToString('N')) -Force }

        $result = Invoke-AgentTask -Request $req -Config $cfg
        Send-Json -Context $context -Status 200 -Json ($result | ConvertTo-Json -Depth 8 -Compress)
    } catch {
        try { Send-Json -Context $context -Status 500 -Json (@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress) } catch { }
    }
}
