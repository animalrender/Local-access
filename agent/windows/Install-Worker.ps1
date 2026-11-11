<#
.SYNOPSIS
    One-time setup of the Local-access agent worker on Windows.

.DESCRIPTION
    * checks the GitHub token and refuses to use a PUBLIC repository
    * stores the token with DPAPI (current user only, never on a command line)
    * writes agent.config.json with the folders the agent may touch
    * runs a local self-test (ping / exec / write / read / hash / sandbox)
    * verifies the GitHub permissions the worker needs (create+comment+close)
    * registers a scheduled task that starts the worker at logon, and starts it

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-Worker.ps1 -Repo animalrender/Local-access

.EXAMPLE
    .\Install-Worker.ps1 -Repo animalrender/Local-access -Roots 'C:\Users\me','D:\projects' -RunNow
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$Token = '',
    [string[]]$Roots = @(),
    [int]$IntervalSec = 5,
    [string]$TaskName = 'LocalAccessAgentWorker',
    [switch]$NoTask,
    [switch]$SelfTestOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$here = $PSScriptRoot
$dataDir = Join-Path $env:LOCALAPPDATA 'win-agent'
$configPath = Join-Path $dataDir 'agent.config.json'
$tokenFile = Join-Path $dataDir 'token.dpapi'
$statePath = Join-Path $dataDir 'state.json'
$logPath = Join-Path $dataDir 'worker.log'
$launcher = Join-Path $dataDir 'run-worker.cmd'

function Step { param([string]$Text) Write-Host "`n== $Text" -ForegroundColor Cyan }
function Ok   { param([string]$Text) Write-Host "   ok   $Text" -ForegroundColor Green }
function Warn { param([string]$Text) Write-Host "   !    $Text" -ForegroundColor Yellow }
function Die  { param([string]$Text) Write-Host "`nFAILED: $Text" -ForegroundColor Red; exit 1 }

function Invoke-Gh {
    param([string]$Method, [string]$Path, $Body = $null)
    $headers = @{
        'Authorization'        = "Bearer $script:PlainToken"
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'local-access-installer/1.1.0'
    }
    $params = @{ Method = $Method; Uri = ('https://api.github.com' + $Path); Headers = $headers; TimeoutSec = 45 }
    if ($null -ne $Body) {
        $params['Body'] = ($Body | ConvertTo-Json -Compress -Depth 6)
        $params['ContentType'] = 'application/json; charset=utf-8'
    }
    return Invoke-RestMethod @params
}

Write-Host 'Local-access agent worker - setup' -ForegroundColor White
Write-Host ('PowerShell {0}' -f $PSVersionTable.PSVersion)
if ($PSVersionTable.PSVersion.Major -lt 3) { Die 'PowerShell 3 or newer is required (5.1 recommended)' }
if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Force -Path $dataDir | Out-Null }

# --------------------------------------------------------------------------- #
Step '1/6  GitHub token'
# --------------------------------------------------------------------------- #
$script:PlainToken = $Token
if (-not $script:PlainToken) { $script:PlainToken = $env:GITHUB_TOKEN }
if (-not $script:PlainToken -and (Test-Path -LiteralPath $tokenFile)) {
    try {
        $secure = ConvertTo-SecureString (Get-Content -LiteralPath $tokenFile -Raw)
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $script:PlainToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        Ok 'using the token already stored on this machine'
    } catch { }
}
if (-not $script:PlainToken) {
    Write-Host 'Paste a fine-grained PAT (Repository permissions -> Issues: Read and write):' -ForegroundColor Yellow
    $script:PlainToken = (Read-Host 'token').Trim()
}
if (-not $script:PlainToken) { Die 'no token given' }

try { $repoInfo = Invoke-Gh -Method GET -Path "/repos/$Repo" }
catch { Die "cannot read $Repo (HTTP error). Check the token scope and the repo name.`n$($_.Exception.Message)" }
Ok ("repository: {0} (private={1})" -f $repoInfo.full_name, $repoInfo.private)

if (-not $repoInfo.private -and -not $Force) {
    Die @"
$Repo is PUBLIC. Everything the agent reads (file contents, command output)
would be visible to the whole internet.

Fix it first:  repo -> Settings -> General -> Danger Zone -> Change visibility -> Private
then run this script again.  (-Force overrides, if you really mean it)
"@
}

$secureToken = ConvertTo-SecureString $script:PlainToken -AsPlainText -Force
ConvertFrom-SecureString $secureToken | Set-Content -LiteralPath $tokenFile -Encoding ASCII
try { icacls $tokenFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null } catch { Warn 'could not tighten ACLs on the token file' }
Ok "token stored at $tokenFile (DPAPI, user-scoped)"

# --------------------------------------------------------------------------- #
Step '2/6  GitHub permissions'
# --------------------------------------------------------------------------- #
# the worker needs: read issues, comment on issues, close issues
$probe = $null
try {
    $probe = Invoke-Gh -Method POST -Path "/repos/$Repo/issues" -Body @{
        title = '[agent] permission self-test (safe to close)'
        body  = 'created by Install-Worker.ps1 to verify Issues permissions; closed automatically'
    }
    Ok 'can create issues (this is how the agent sends requests)'
    Invoke-Gh -Method POST -Path ("/repos/$Repo/issues/{0}/comments" -f $probe.number) -Body @{ body = 'permission probe' } | Out-Null
    Ok 'can comment on issues (this is how the worker answers)'
    Invoke-Gh -Method PATCH -Path ("/repos/$Repo/issues/{0}" -f $probe.number) -Body @{ state = 'closed' } | Out-Null
    Ok 'can close issues'
} catch {
    Die @"
the token is missing the "Issues: Read and write" permission on $Repo.
  GitHub -> Settings -> Developer settings -> Fine-grained tokens -> your token
        -> Repository permissions -> Issues -> Read and write -> Save
then run this script again.
($($_.Exception.Message))
"@
}

# --------------------------------------------------------------------------- #
Step '3/6  path sandbox'
# --------------------------------------------------------------------------- #
if ($Roots.Count -eq 0) { $Roots = @($env:USERPROFILE, (Join-Path $env:TEMP 'win-agent')) }
$cleanRoots = @()
foreach ($root in $Roots) {
    $full = [System.IO.Path]::GetFullPath([System.Environment]::ExpandEnvironmentVariables($root))
    if (-not (Test-Path -LiteralPath $full)) { Warn "root does not exist yet (ignored until it does): $full" }
    $cleanRoots += $full
}
if ((Test-Path -LiteralPath $configPath) -and -not $Force) {
    Ok "keeping the existing config: $configPath (use -Force to rewrite)"
    $cfgExisting = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($cfgExisting.allowedRoots) { $cleanRoots = @($cfgExisting.allowedRoots) }
} else {
    $config = [ordered]@{
        allowedRoots      = @($cleanRoots)
        allowExec         = $true
        allowRead         = $true
        allowWrite        = $true
        allowHash         = $true
        maxReadBytes      = 4194304
        maxWriteBytes     = 33554432
        maxOutputBytes    = 1048576
        defaultTimeoutSec = 120
        maxTimeoutSec     = 900
        maxListEntries    = 400
        progressEverySec  = 20
    }
    [System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    Ok "config written: $configPath"
}
Ok ("allowed roots: " + ($cleanRoots -join '; '))

# --------------------------------------------------------------------------- #
Step '4/6  local self-test'
# --------------------------------------------------------------------------- #
. (Join-Path $here 'AgentTask.ps1')
$cfg = Get-AgentConfig -Path $configPath
$script:failures = 0

function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { Ok $Name } else { Write-Host "   FAIL $Name $Detail" -ForegroundColor Red; $script:failures++ }
}

$ping = Invoke-AgentTask -Request ([pscustomobject]@{ req = 'selftest-ping'; op = 'ping' }) -Config $cfg
Check 'ping' ($ping.ok -eq $true) ([string]$ping.error)

$exec = Invoke-AgentTask -Request ([pscustomobject]@{ req = 'selftest-exec'; op = 'exec'; script = "Write-Output 'hello'; Write-Output 'فارسی'" }) -Config $cfg
Check 'exec' ($exec.ok -eq $true -and $exec.stdout -match 'hello') ([string]$exec.error)
Check 'exec keeps utf-8 output' ($exec.stdout -match 'فارسی')

$target = Join-Path $env:TEMP ('agent-selftest-' + [Guid]::NewGuid().ToString('N') + '.txt')
$payload = [System.Text.Encoding]::UTF8.GetBytes('line1' + "`r`n" + 'خط دوم')
$write = Invoke-AgentTask -Request ([pscustomobject]@{ req = 'selftest-write'; op = 'write'; path = $target; mode = 'overwrite'; data_base64 = [System.Convert]::ToBase64String($payload) }) -Config $cfg
Check 'write' ($write.ok -eq $true) ([string]$write.error)

$read = Invoke-AgentTask -Request ([pscustomobject]@{ req = 'selftest-read'; op = 'read'; path = $target; offset = 0; length = 4096 }) -Config $cfg
Check 'read' ($read.ok -eq $true) ([string]$read.error)
if ($read.ok) {
    $text = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($read.result.data_base64))
    Check 'read returns the same bytes' ($text -match 'خط دوم')
}

$hash = Invoke-AgentTask -Request ([pscustomobject]@{ req = 'selftest-hash'; op = 'hash'; path = $target }) -Config $cfg
Check 'hash' ($hash.ok -and $hash.result.sha256 -match '^[0-9a-f]{64}$') ([string]$hash.error)

$outside = "$env:SystemRoot\win.ini"
if (-not ($cleanRoots | Where-Object { $outside.ToLower().StartsWith($_.ToLower()) })) {
    $blocked = Invoke-AgentTask -Request ([pscustomobject]@{ req = 'selftest-block'; op = 'read'; path = $outside }) -Config $cfg
    Check 'sandbox refuses paths outside the roots' ($blocked.ok -eq $false) 'the sandbox is NOT enforcing allowedRoots'
}
Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue

if ($script:failures -gt 0) { Die "$($script:failures) self-test(s) failed - do not use the bridge until this is fixed" }
Ok 'all self-tests passed'

if ($SelfTestOnly) { Write-Host "`nself-test only: nothing was installed"; exit 0 }

# --------------------------------------------------------------------------- #
Step '5/6  scheduled task'
# --------------------------------------------------------------------------- #
$workerArgs = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Repo {1} -IntervalSec {2} -ConfigPath "{3}" -StatePath "{4}" -LogPath "{5}"' -f `
    (Join-Path $here 'AgentWorker.ps1'), $Repo, $IntervalSec, $configPath, $statePath, $logPath
$cmdLine = '@echo off' + "`r`n" + 'powershell.exe ' + $workerArgs + "`r`n"
[System.IO.File]::WriteAllText($launcher, $cmdLine, (New-Object System.Text.ASCIIEncoding))

if ($NoTask) {
    Warn '-NoTask given: scheduled task not created'
} else {
    & schtasks.exe /Query /TN $TaskName *> $null
    $exists = ($LASTEXITCODE -eq 0)
    if ($exists -and -not $Force) {
        Ok "scheduled task '$TaskName' already exists (use -Force to recreate)"
    } else {
        if ($exists) { & schtasks.exe /Delete /TN $TaskName /F *> $null }
        & schtasks.exe /Create /TN $TaskName /TR "`"$launcher`"" /SC ONLOGON /RL LIMITED /F *> $null
        if ($LASTEXITCODE -ne 0) {
            Warn "could not register the scheduled task (code $LASTEXITCODE); run manually: $launcher"
        } else {
            Ok "scheduled task '$TaskName' created (starts at logon)"
        }
    }
}

# --------------------------------------------------------------------------- #
Step '6/6  start'
# --------------------------------------------------------------------------- #
Start-Process -FilePath $launcher -WindowStyle Hidden
Start-Sleep -Seconds 3
Ok 'worker started in the background'

Write-Host ''
Write-Host 'Done - the agent can use this PC now.' -ForegroundColor Green
Write-Host "  check from the agent:  scripts/agent.py ping"
Write-Host "  worker log:            $logPath"
Write-Host "  stop it:               schtasks /Delete /TN $TaskName /F   (then: Stop-Process -Name powershell)"
