<#
.SYNOPSIS
    Local-access agent worker for Windows.

.DESCRIPTION
    Polls the repository for open request issues (title starts with
    "[agent-req]"), executes each one through AgentTask.ps1, posts the result as
    a comment on that issue, and closes it.

    Outbound HTTPS to api.github.com is the only network requirement: no inbound
    port, no public IP, no tunnel, works behind CGNAT.

    The agent side cannot comment on issues (its token is read-only for
    comments), which is exactly why a request is one issue and an answer is one
    comment.  See ../PROTOCOL.md.

.NOTES
    Windows PowerShell 5.1 compatible.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repo,

    [string]$Token = '',
    [string]$TokenFile = '',
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'agent.config.json'),
    [string]$StatePath = (Join-Path $env:LOCALAPPDATA 'win-agent\state.json'),
    [string]$LogPath = (Join-Path $env:LOCALAPPDATA 'win-agent\worker.log'),
    [string]$Prefix = '[agent-req]',
    [int]$IntervalSec = 5,
    [switch]$Once,
    [switch]$Init,
    [switch]$Replay,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

. (Join-Path $PSScriptRoot 'AgentTask.ps1')

$script:ReqPattern = '<!--AGENT:REQ:v1:([A-Za-z0-9+/=]+)-->'
$script:ResPattern = '<!--AGENT:RES:v1:([A-Za-z0-9+/=]+)-->'
$script:ApiBase = 'https://api.github.com'
$script:MaxCommentLength = 60000

# --------------------------------------------------------------------------- #
# logging / state
# --------------------------------------------------------------------------- #
function Write-AgentLog {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Message
    if (-not $Quiet) { Write-Host $line }
    try {
        $dir = [System.IO.Path]::GetDirectoryName($LogPath)
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { }
}

function Get-PlainToken {
    param([string]$FromParam, [string]$FromFile)

    if ($FromParam) { return $FromParam.Trim() }
    if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN.Trim() }
    if (-not $FromFile) { $FromFile = Join-Path $env:LOCALAPPDATA 'win-agent\token.dpapi' }
    if (Test-Path -LiteralPath $FromFile) {
        $secure = ConvertTo-SecureString (Get-Content -LiteralPath $FromFile -Raw)
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr).Trim() }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    throw "no GitHub token: pass -Token, set GITHUB_TOKEN, or run Install-Worker.ps1 (expected $FromFile)"
}

function Load-State {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        try {
            $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            if (-not $state.PSObject.Properties['done_issues']) {
                $state | Add-Member -NotePropertyName done_issues -NotePropertyValue @() -Force
            }
            if (-not $state.PSObject.Properties['done_reqs']) {
                $state | Add-Member -NotePropertyName done_reqs -NotePropertyValue @() -Force
            }
            return $state
        } catch { }
    }
    return [pscustomobject]@{ done_issues = @(); done_reqs = @() }
}

function Save-State {
    param([string]$Path, [object]$State)
    if (@($State.done_issues).Count -gt 500) { $State.done_issues = @(@($State.done_issues) | Select-Object -Last 500) }
    if (@($State.done_reqs).Count -gt 500) { $State.done_reqs = @(@($State.done_reqs) | Select-Object -Last 500) }
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, ($State | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
}

# --------------------------------------------------------------------------- #
# github
# --------------------------------------------------------------------------- #
function Invoke-GitHub {
    param(
        [string]$Method,
        [string]$Path,
        $Body = $null,
        [int]$MaxAttempts = 4
    )

    $uri = $script:ApiBase + $Path
    $headers = @{
        'Authorization'        = "Bearer $script:Token"
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = "local-access-agent-worker/$script:AgentWorkerVersion"
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $params = @{ Method = $Method; Uri = $uri; Headers = $headers; TimeoutSec = 45 }
            if ($null -ne $Body) {
                $params['Body'] = ($Body | ConvertTo-Json -Compress -Depth 6)
                $params['ContentType'] = 'application/json; charset=utf-8'
            }
            return Invoke-RestMethod @params
        } catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            if ($status -in @(401, 403, 404) -and $Body -ne $null) {
                throw "GitHub $Method $Path failed (HTTP $status): $($_.Exception.Message)"
            }
            if ($attempt -eq $MaxAttempts) { throw }
            Start-Sleep -Seconds ([math]::Min(30, 3 * $attempt))
        }
    }
}

function Get-OpenRequests {
    $issues = Invoke-GitHub -Method GET -Path ("/repos/{0}/issues?state=open&per_page=50&sort=created&direction=asc" -f $Repo)
    $out = @()
    foreach ($issue in @($issues)) {
        if ($null -eq $issue) { continue }
        if ($issue.PSObject.Properties['pull_request'] -and $issue.pull_request) { continue }
        if ([string]$issue.title -like "$Prefix*") { $out += $issue }
    }
    return $out
}

function Send-IssueComment {
    param([int]$Number, [string]$Body)
    if ($Body.Length -gt $script:MaxCommentLength) { throw "comment too large ($($Body.Length) chars)" }
    return Invoke-GitHub -Method POST -Path ("/repos/{0}/issues/{1}/comments" -f $Repo, $Number) -Body @{ body = $Body }
}

function Close-Issue {
    param([int]$Number)
    try {
        Invoke-GitHub -Method PATCH -Path ("/repos/{0}/issues/{1}" -f $Repo, $Number) -Body @{ state = 'closed'; state_reason = 'completed' } | Out-Null
    } catch {
        Write-AgentLog ("warning: could not close #{0}: {1}" -f $Number, $_.Exception.Message)
    }
}

# --------------------------------------------------------------------------- #
# envelopes
# --------------------------------------------------------------------------- #
function ConvertFrom-AgentEnvelope {
    param([string]$Body, [string]$Pattern)

    if ([string]::IsNullOrEmpty($Body)) { return $null }
    $match = [regex]::Match($Body, $Pattern)
    if (-not $match.Success) { return $null }
    try {
        $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($match.Groups[1].Value))
        return ($json | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function ConvertTo-AgentEnvelope {
    param([object]$Object, [string]$Kind)

    $json = $Object | ConvertTo-Json -Depth 8 -Compress
    $b64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
    return ('<!--AGENT:' + $Kind + ':v1:' + $b64 + '-->')
}

function Compress-AgentResult {
    param([object]$Result)

    $envelope = ConvertTo-AgentEnvelope -Object $Result -Kind 'RES'
    if ($envelope.Length -le $script:MaxCommentLength) { return $envelope }

    $copy = $Result | ConvertTo-Json -Depth 8 -Compress | ConvertFrom-Json
    if ($copy.stdout) {
        $copy.stdout = $copy.stdout.Substring(0, [math]::Min(3000, $copy.stdout.Length))
        $copy | Add-Member -NotePropertyName stdout_truncated -NotePropertyValue $true -Force
    }
    if ($copy.result -and $copy.result.PSObject.Properties['data_base64']) {
        $copy.result.data_base64 = ''
        $copy.result | Add-Member -NotePropertyName note -NotePropertyValue 'payload too large for one comment; re-read with offset/length' -Force
    }

    # a recursive directory listing can be huge: keep as many entries as fit
    if ($copy.result -and $copy.result.PSObject.Properties['entries'] -and @($copy.result.entries).Count -gt 0) {
        $entries = @($copy.result.entries)
        $keep = $entries.Count
        while ($keep -gt 1) {
            $keep = [int]($keep / 2)
            $copy.result.entries = @($entries[0..($keep - 1)])
            $copy.result | Add-Member -NotePropertyName count -NotePropertyValue $keep -Force
            $copy.result | Add-Member -NotePropertyName truncated -NotePropertyValue $true -Force
            $copy.result | Add-Member -NotePropertyName total_entries -NotePropertyValue $entries.Count -Force
            if ((ConvertTo-AgentEnvelope -Object $copy -Kind 'RES').Length -le $script:MaxCommentLength) { break }
        }
    }
    return (ConvertTo-AgentEnvelope -Object $copy -Kind 'RES')
}

# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
$script:Token = Get-PlainToken -FromParam $Token -FromFile $TokenFile
$script:Repo = $Repo

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\LocalAccessAgentWorker', [ref]$createdNew)
if (-not $createdNew) {
    Write-Warning 'another AgentWorker is already running for this session; exiting'
    return
}

$config = Get-AgentConfig -Path $ConfigPath
$state = Load-State -Path $StatePath

Write-AgentLog ("worker {0} up: repo={1} prefix='{2}' interval={3}s roots={4}" -f $script:AgentWorkerVersion, $Repo, $Prefix, $IntervalSec, ($config.allowedRoots -join '; '))

$pending = Get-OpenRequests

if ($Init) {
    foreach ($issue in @($pending)) {
        $state.done_issues = @(@($state.done_issues) + [int]$issue.number)
    }
    Save-State -Path $StatePath -State $state
    Write-AgentLog ("initialised: {0} open request(s) marked as handled" -f @($pending).Count)
    return
}

$running = $true
while ($running) {
    try {
        $pending = Get-OpenRequests
    } catch {
        Write-AgentLog ("poll failed: {0}" -f $_.Exception.Message)
        Start-Sleep -Seconds ([math]::Max(5, $IntervalSec * 2))
        continue
    }

    foreach ($issue in @($pending)) {
        $number = [int]$issue.number
        $request = ConvertFrom-AgentEnvelope -Body ([string]$issue.body) -Pattern $script:ReqPattern

        if ($null -eq $request) {
            # leftover bridge issue without a valid payload: tidy it up
            if ([string]$issue.title -like '[agent]*') {
                Write-AgentLog ("issue #{0}: no request envelope, closing" -f $number)
                Close-Issue -Number $number
            }
            continue
        }

        $reqId = [string](Get-AgentProp $request 'req' 'unknown')
        $op = [string](Get-AgentProp $request 'op' '')

        $done = (@($state.done_issues) -contains $number) -or (@($state.done_reqs) -contains $reqId)
        if ($done -and -not $Replay) {
            Close-Issue -Number $number
            continue
        }

        Write-AgentLog ("run {0} (issue #{1}) op={2}" -f $reqId, $number, $op)

        $script:lastPartialTime = Get-Date
        $progress = {
            param($tail, $elapsed)
            try {
                if (((Get-Date) - $script:lastPartialTime).TotalSeconds -lt $config.progressEverySec) { return }
                $script:lastPartialTime = Get-Date
                $partial = [pscustomobject]@{
                    v           = 1
                    req         = $reqId
                    partial     = $true
                    elapsed_sec = $elapsed
                    stdout      = (Update-AgentTail -Text $tail -Max 1200)
                }
                Send-IssueComment -Number $number -Body (ConvertTo-AgentEnvelope -Object $partial -Kind 'RES') | Out-Null
            } catch { }
        }

        $result = Invoke-AgentTask -Request $request -Config $config -OnProgress $progress `
            -OutDir (Join-Path $env:LOCALAPPDATA "win-agent\results\$reqId")

        try {
            Send-IssueComment -Number $number -Body (Compress-AgentResult -Result $result) | Out-Null
            Write-AgentLog ("result {0} ok={1}" -f $reqId, $result.ok)
        } catch {
            Write-AgentLog ("post failed for {0}: {1}" -f $reqId, $_.Exception.Message)
        }

        $state.done_issues = @(@($state.done_issues) + $number)
        $state.done_reqs = @(@($state.done_reqs) + $reqId)
        Save-State -Path $StatePath -State $state
        Close-Issue -Number $number
    }

    if ($Once) { break }
    Start-Sleep -Seconds ([math]::Max(1, $IntervalSec))
}

try { $mutex.ReleaseMutex() } catch { }
