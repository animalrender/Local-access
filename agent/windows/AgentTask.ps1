<#
.SYNOPSIS
    Executor for the Local-access agent bridge (Windows side).

.DESCRIPTION
    Dot-source this file, then call Invoke-AgentTask with one request object
    (see ../PROTOCOL.md).  It runs exactly one operation — exec / ping / info /
    ls / read / write / hash — inside a path sandbox and returns one result
    object, which the worker posts back to the mailbox.

    Windows PowerShell 5.1 compatible (no PS7-only syntax).

.EXAMPLE
    . .\AgentTask.ps1
    $cfg = Get-AgentConfig -Path .\agent.config.json
    Invoke-AgentTask -Request ([pscustomobject]@{ req = 'r-1'; op = 'ping' }) -Config $cfg
#>

$script:AgentWorkerVersion = '1.0.0'

function Get-AgentDefaultConfig {
    [pscustomobject]@{
        allowedRoots      = @($env:USERPROFILE, (Join-Path $env:TEMP 'win-agent'))
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
}

function Get-AgentConfig {
    param([string]$Path)

    $cfg = Get-AgentDefaultConfig
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try {
            $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
            $user = $raw | ConvertFrom-Json
            foreach ($prop in $user.PSObject.Properties) {
                if ($cfg.PSObject.Properties[$prop.Name]) {
                    $cfg.($prop.Name) = $prop.Value
                } else {
                    $cfg | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
                }
            }
        } catch {
            throw "cannot parse config '$Path': $($_.Exception.Message)"
        }
    }
    if (-not $cfg.allowedRoots -or $cfg.allowedRoots.Count -eq 0) {
        $cfg.allowedRoots = @($env:USERPROFILE)
    }
    return $cfg
}

function Resolve-AgentPath {
    param(
        [string]$Path,
        [object]$Config,
        [switch]$MustExist
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'path is required' }

    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ($expanded -eq '~') { $expanded = $env:USERPROFILE }
    if ($expanded.StartsWith('~\') -or $expanded.StartsWith('~/')) {
        $expanded = Join-Path $env:USERPROFILE $expanded.Substring(2)
    }
    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        throw "path must be absolute: $Path"
    }

    $full = [System.IO.Path]::GetFullPath($expanded)
    $probe = $full.TrimEnd('\')
    if ($probe.Length -eq 1) { $probe = $full }   # keep drive roots as 'C:\'

    $allowed = $false
    foreach ($root in $Config.allowedRoots) {
        $r = [System.IO.Path]::GetFullPath([System.Environment]::ExpandEnvironmentVariables([string]$root)).TrimEnd('\')
        if ($r.Length -eq 2 -and $r.EndsWith(':')) { $r = $r + '\' }
        if ($probe.Equals($r.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) { $allowed = $true; break }
        if ($probe.StartsWith($r.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $allowed = $true; break }
    }
    if (-not $allowed) {
        throw "path outside allowed roots: $full (allowed: $($Config.allowedRoots -join '; '))"
    }
    if ($MustExist -and -not (Test-Path -LiteralPath $full)) {
        throw "not found: $full"
    }
    return $full
}

function Get-AgentProp {
    param([object]$Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function ConvertTo-AgentBase64 {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    return [System.Convert]::ToBase64String($Bytes)
}

function Update-AgentTail {
    param([string]$Text, [int]$Max = 1500)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring($Text.Length - $Max)
}

# --------------------------------------------------------------------------- #
# operations
# --------------------------------------------------------------------------- #
function Invoke-AgentExec {
    param(
        [object]$Request,
        [object]$Config,
        [string]$WorkRoot,
        [string]$LogsDir,
        [scriptblock]$OnProgress
    )

    if (-not $Config.allowExec) { throw 'exec is disabled (allowExec=false)' }

    $script = [string](Get-AgentProp $Request 'script' '')
    if ([string]::IsNullOrWhiteSpace($script)) { throw "exec requires 'script'" }

    $shell = [string](Get-AgentProp $Request 'shell' 'powershell')
    $timeout = [int](Get-AgentProp $Request 'timeout_sec' $Config.defaultTimeoutSec)
    if ($timeout -lt 1) { $timeout = 1 }
    if ($timeout -gt $Config.maxTimeoutSec) { $timeout = $Config.maxTimeoutSec }

    $runId = [Guid]::NewGuid().ToString('N')
    $work = Join-Path $WorkRoot ("exec-$runId")
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    $outFile = Join-Path $work 'stdout.txt'
    $errFile = Join-Path $work 'stderr.txt'

    if ($shell -match '^(cmd|cmd\.exe)$') {
        $scriptPath = Join-Path $work 'task.cmd'
        $exe = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $arguments = '/d /c ""{0}""' -f $scriptPath
        $body = $script
        $encoding = New-Object System.Text.UTF8Encoding($false)
    } else {
        $scriptPath = Join-Path $work 'task.ps1'
        $exe = (Get-Command powershell.exe -ErrorAction Stop).Source
        $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath
        $body = @(
            '$ErrorActionPreference = ''Continue'''
            '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8'
            '$OutputEncoding = [System.Text.Encoding]::UTF8'
            'try {'
            $script
            '} catch { Write-Error $_ }'
        ) -join "`r`n"
        $encoding = New-Object System.Text.UTF8Encoding($true)   # BOM so 5.1 reads UTF-8
    }
    [System.IO.File]::WriteAllText($scriptPath, $body, $encoding)

    $cwd = $WorkRoot
    $rawCwd = Get-AgentProp $Request 'cwd' ''
    if ($rawCwd) { $cwd = Resolve-AgentPath -Path ([string]$rawCwd) -Config $Config -MustExist }

    $started = Get-Date
    $proc = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $cwd `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -WindowStyle Hidden -PassThru

    $timedOut = $false
    $deadline = $started.AddSeconds($timeout)
    $lastProgress = $started
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 200
        if ((Get-Date) -gt $deadline) {
            $timedOut = $true
            & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null
            try { $proc.WaitForExit(5000) | Out-Null } catch { }
            break
        }
        if ($OnProgress) {
            $now = Get-Date
            if (($now - $lastProgress).TotalSeconds -ge $Config.progressEverySec) {
                $lastProgress = $now
                $tail = ''
                try { if (Test-Path -LiteralPath $outFile) { $tail = Update-AgentTail ([System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8)) } } catch { }
                try { & $OnProgress $tail ([int]($now - $started).TotalSeconds) } catch { }
            }
        }
    }
    if (-not $timedOut) { try { $proc.WaitForExit(10000) | Out-Null } catch { } }

    $duration = [int]((Get-Date) - $started).TotalMilliseconds
    $stdout = ''
    $stderr = ''
    try { if (Test-Path -LiteralPath $outFile) { $stdout = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8) } } catch { }
    try { if (Test-Path -LiteralPath $errFile) { $stderr = [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8) } } catch { }

    $cap = [int]$Config.maxOutputBytes
    if ($stdout.Length -gt $cap) { $stdout = $stdout.Substring(0, $cap) }
    if ($stderr.Length -gt $cap) { $stderr = $stderr.Substring(0, $cap) }

    $reqId = [string](Get-AgentProp $Request 'req' 'unknown')
    $logPath = Join-Path $LogsDir ("$reqId.stdout.txt")
    try {
        if (-not (Test-Path -LiteralPath $LogsDir)) { New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null }
        [System.IO.File]::WriteAllText($logPath, $stdout, (New-Object System.Text.UTF8Encoding($false)))
    } catch { $logPath = '' }

    $exitCode = $null
    try { $exitCode = $proc.ExitCode } catch { }

    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        exit_code = $exitCode
        timed_out = $timedOut
        duration_ms = $duration
        stdout    = $stdout
        stderr    = $stderr
        log_path  = $logPath
        cwd       = $cwd
    }
}

function Invoke-AgentList {
    param([object]$Request, [object]$Config)

    $path = Resolve-AgentPath -Path ([string](Get-AgentProp $Request 'path' '~')) -Config $Config -MustExist
    $recursive = [bool](Get-AgentProp $Request 'recursive' $false)
    $pattern = [string](Get-AgentProp $Request 'pattern' '*')
    if (-not $pattern) { $pattern = '*' }
    if ($recursive -and $pattern -eq '*') { $pattern = '*' }

    $limit = [int]$Config.maxListEntries
    $entries = New-Object System.Collections.ArrayList
    $truncated = $false

    $items = @()
    if ($recursive) {
        $items = Get-ChildItem -LiteralPath $path -Force -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\\.git\\' }
    } else {
        $items = Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }

    foreach ($item in $items) {
        if ($items.Count -gt 0 -and $pattern -ne '*' -and -not $recursive) {
            if (-not ($item.Name -like $pattern)) { continue }
        }
        if ($entries.Count -ge $limit) { $truncated = $true; break }
        $size = $null
        if (-not $item.PSIsContainer) { $size = [long]$item.Length }
        [void]$entries.Add([pscustomobject]@{
            name  = $item.Name
            path  = $item.FullName
            type  = $(if ($item.PSIsContainer) { 'dir' } else { 'file' })
            size  = $size
            mtime = $item.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        })
    }

    return [pscustomobject]@{
        path      = $path
        entries   = $entries.ToArray()
        count     = $entries.Count
        truncated = $truncated
    }
}

function Invoke-AgentRead {
    param([object]$Request, [object]$Config)

    if (-not $Config.allowRead) { throw 'reads are disabled (allowRead=false)' }
    $path = Resolve-AgentPath -Path ([string](Get-AgentProp $Request 'path' '')) -Config $Config -MustExist
    if (Test-Path -LiteralPath $path -PathType Container) { throw "path is a directory: $path" }

    $maxRead = [int]$Config.maxReadBytes
    $offset = [long](Get-AgentProp $Request 'offset' 0)
    if ($offset -lt 0) { $offset = 0 }
    $length = [int](Get-AgentProp $Request 'length' 30000)
    if ($length -lt 1) { $length = 1 }
    if ($length -gt $maxRead) { $length = $maxRead }

    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $size = $stream.Length
        if ($offset -gt $size) { $offset = $size }
        $stream.Position = $offset
        $buffer = New-Object byte[] $length
        $read = 0
        while ($read -lt $length) {
            $n = $stream.Read($buffer, $read, $length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
    } finally {
        $stream.Dispose()
    }
    if ($read -lt $length) {
        if ($read -eq 0) { $buffer = New-Object byte[] 0 } else { $buffer = $buffer[0..($read - 1)] }
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($buffer) } finally { $sha.Dispose() }

    return [pscustomobject]@{
        path        = $path
        size        = $size
        offset      = $offset
        length      = $read
        eof         = (($offset + $read) -ge $size)
        sha256      = ([System.BitConverter]::ToString($hash) -replace '-', '').ToLower()
        data_base64 = (ConvertTo-AgentBase64 -Bytes $buffer)
    }
}

function Invoke-AgentWrite {
    param([object]$Request, [object]$Config)

    if (-not $Config.allowWrite) { throw 'writes are disabled (allowWrite=false)' }
    $path = Resolve-AgentPath -Path ([string](Get-AgentProp $Request 'path' '')) -Config $Config
    if (Test-Path -LiteralPath $path -PathType Container) { throw "path is a directory: $path" }

    $b64 = [string](Get-AgentProp $Request 'data_base64' '')
    $bytes = @()
    if ($b64) { $bytes = [System.Convert]::FromBase64String($b64) }
    if ($bytes.Length -gt [int]$Config.maxWriteBytes) {
        throw ("payload too large: {0} > {1} bytes" -f $bytes.Length, $Config.maxWriteBytes)
    }

    $mode = [string](Get-AgentProp $Request 'mode' 'overwrite')
    if ($mode -notin @('overwrite', 'append')) { throw 'mode must be overwrite|append' }

    $parent = [System.IO.Path]::GetDirectoryName($path)
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        if ([bool](Get-AgentProp $Request 'create_dirs' $true)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        } else {
            throw "directory does not exist: $parent"
        }
    }

    if ($bytes.Length -gt 0) {
        if ($mode -eq 'append') {
            $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
            try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
        } else {
            [System.IO.File]::WriteAllBytes($path, $bytes)
        }
    } elseif ($mode -eq 'overwrite') {
        [System.IO.File]::WriteAllBytes($path, (New-Object byte[] 0))
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }

    return [pscustomobject]@{
        path          = $path
        bytes_written = $bytes.Length
        mode          = $mode
        size          = (Get-Item -LiteralPath $path).Length
        sha256        = ([System.BitConverter]::ToString($hash) -replace '-', '').ToLower()
    }
}

function Invoke-AgentHash {
    param([object]$Request, [object]$Config)

    if (-not $Config.allowHash) { throw 'hashing is disabled (allowHash=false)' }
    $path = Resolve-AgentPath -Path ([string](Get-AgentProp $Request 'path' '')) -Config $Config -MustExist
    if (Test-Path -LiteralPath $path -PathType Container) { throw "path is a directory: $path" }
    $item = Get-Item -LiteralPath $path
    return [pscustomobject]@{
        path   = $path
        size   = $item.Length
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
        mtime  = $item.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
}

function Invoke-AgentInfo {
    param([object]$Request, [object]$Config, [string]$WorkRoot)

    $tailscale = $null
    $ts = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($null -eq $ts) { $ts = Get-Command tailscale -ErrorAction SilentlyContinue }
    if ($ts) {
        $ip = ''
        try { $ip = (& $ts.Source ip -4 2>$null | Out-String).Trim() } catch { }
        $tailscale = [pscustomobject]@{ path = $ts.Source; ip4 = $ip }
    }

    $drives = @()
    try {
        $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ name = $_.Name; used_gb = [math]::Round($_.Used / 1GB, 1); free_gb = [math]::Round($_.Free / 1GB, 1) }
        })
    } catch { }

    $envSample = [ordered]@{}
    foreach ($key in @('USERNAME', 'USERPROFILE', 'COMPUTERNAME', 'TEMP', 'PROCESSOR_ARCHITECTURE')) {
        $value = [System.Environment]::GetEnvironmentVariable($key)
        if ($value) { $envSample[$key] = $value }
    }

    return [pscustomobject]@{
        os          = "$([System.Environment]::OSVersion.VersionString) $([System.Environment]::Is64BitOperatingSystem)",
        ps_version  = $PSVersionTable.PSVersion.ToString()
        net_version = $PSVersionTable.CLRVersion.ToString()
        machine     = $env:PROCESSOR_ARCHITECTURE
        drives      = $drives
        env_sample  = [pscustomobject]$envSample
        tailscale   = $tailscale
        work_root   = $WorkRoot
        dotnet      = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
        git         = (Get-Command git -ErrorAction SilentlyContinue).Source
    }
}

# --------------------------------------------------------------------------- #
# entry point
# --------------------------------------------------------------------------- #
function Invoke-AgentTask {
    param(
        [Parameter(Mandatory = $true)][object]$Request,
        [object]$Config = $null,
        [string]$WorkRoot = (Join-Path $env:LOCALAPPDATA 'win-agent\work'),
        [string]$LogsDir = (Join-Path $env:LOCALAPPDATA 'win-agent\logs'),
        [string]$OutDir = '',
        [scriptblock]$OnProgress = $null
    )

    if ($null -eq $Config) { $Config = Get-AgentDefaultConfig }
    foreach ($dir in @($WorkRoot, $LogsDir)) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    }

    $reqId = [string](Get-AgentProp $Request 'req' 'unknown')
    $op = [string](Get-AgentProp $Request 'op' '')
    $startedAt = Get-Date

    $result = [ordered]@{
        v              = 1
        req            = $reqId
        op             = $op
        worker         = 'windows'
        worker_version = $script:AgentWorkerVersion
        host           = $env:COMPUTERNAME
        user           = $env:USERNAME
        started        = $startedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        ok             = $false
        error          = $null
        exit_code      = $null
    }

    try {
        switch ($op) {
            'ping' {
                $result.result = [pscustomobject]@{
                    config = [pscustomobject]@{
                        allowedRoots     = $Config.allowedRoots
                        allowExec        = $Config.allowExec
                        allowWrite       = $Config.allowWrite
                        maxReadBytes     = $Config.maxReadBytes
                        maxTimeoutSec    = $Config.maxTimeoutSec
                        progressEverySec = $Config.progressEverySec
                    }
                    work_root = $WorkRoot
                    version   = $script:AgentWorkerVersion
                }
            }
            'info' {
                $result.result = Invoke-AgentInfo -Request $Request -Config $Config -WorkRoot $WorkRoot
            }
            'ls' {
                $result.result = Invoke-AgentList -Request $Request -Config $Config
            }
            'read' {
                $result.result = Invoke-AgentRead -Request $Request -Config $Config
            }
            'write' {
                $result.result = Invoke-AgentWrite -Request $Request -Config $Config
            }
            'hash' {
                $result.result = Invoke-AgentHash -Request $Request -Config $Config
            }
            'exec' {
                $payload = Invoke-AgentExec -Request $Request -Config $Config -WorkRoot $WorkRoot -LogsDir $LogsDir -OnProgress $OnProgress
                $result.exit_code = $payload.exit_code
                $result.timed_out = $payload.timed_out
                $result.duration_ms = $payload.duration_ms
                $result.log_path = $payload.log_path
                $result.cwd = $payload.cwd
                $stdout = [string]$payload.stdout
                $stderr = [string]$payload.stderr
                $head = 7000
                $result.stdout = $(if ($stdout.Length -gt $head) { $stdout.Substring(0, $head) } else { $stdout })
                $result.stderr = $(if ($stderr.Length -gt 4000) { $stderr.Substring(0, 4000) } else { $stderr })
                $result.stdout_len = $stdout.Length
                $result.stderr_len = $stderr.Length
                $result.stdout_truncated = ($stdout.Length -gt $head)
                $result.stderr_truncated = ($stderr.Length -gt 4000)
            }
            default {
                throw "unknown op: '$op' (expected exec|ping|info|ls|read|write|hash)"
            }
        }
        $result.ok = $true
    } catch {
        $result.ok = $false
        $result.error = '{0}: {1}' -f $_.Exception.GetType().Name, $_.Exception.Message
    }

    $finishedAt = Get-Date
    $result.finished = $finishedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    if (-not $result.Contains('duration_ms') -or $null -eq $result['duration_ms']) {
        $result['duration_ms'] = [int]($finishedAt - $startedAt).TotalMilliseconds
    }

    $obj = [pscustomobject]$result
    if ($OutDir) {
        if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
        $json = $obj | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText((Join-Path $OutDir 'result.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $obj
}
