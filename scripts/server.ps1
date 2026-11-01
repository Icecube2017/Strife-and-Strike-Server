[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'status', 'signal')]
    [string]$Action = 'start',
    [ValidateRange(1, 65535)][int]$Port = 22216,
    [string]$Hostname = '127.0.0.1',
    [ValidateRange(0, 65535)][int]$VmServicePort = 8181,
    [ValidateRange(1, 60)][int]$StopTimeoutSeconds = 8,
    [ValidateRange(5, 300)][int]$StartupTimeoutSeconds = 60,
    [switch]$Force,
    [int]$ChildProcessId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$scriptPath = $PSCommandPath
$nativePath = Join-Path $PSScriptRoot 'server_job.cs'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$runtime = Join-Path $root ".dart_tool\server-control\$Port"
$statePath = Join-Path $runtime 'state.json'
$hash = [Security.Cryptography.SHA256]::Create()
try { $key = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes("$($root.ToLowerInvariant())|$Port")))).Replace('-', '').Substring(0, 24) }
finally { $hash.Dispose() }
$prefix = "Local\SnsServer_$key"
$mutexName = "${prefix}_mutex"
$stopName = "${prefix}_stop"
$restartName = "${prefix}_restart"
$jobName = "${prefix}_job"

function Import-Native {
    if (-not ('SnsServerControl.ServerJob' -as [type])) { Add-Type -Path $nativePath }
}

function Test-Running {
    $probe = $null
    $acquired = $false
    try {
        try { $probe = [Threading.Mutex]::OpenExisting($mutexName) }
        catch [Threading.WaitHandleCannotBeOpenedException] { return $false }
        try { $acquired = $probe.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        return -not $acquired
    }
    finally {
        if ($acquired) { $probe.ReleaseMutex() }
        if ($null -ne $probe) { $probe.Dispose() }
    }
}

function Read-State {
    $reader = $null
    try {
        # Status/restart polling must allow the supervisor to atomically replace metadata.
        $stream = [IO.FileStream]::new($statePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
        return $reader.ReadToEnd() | ConvertFrom-Json
    }
    catch { return $null }
    finally { if ($null -ne $reader) { $reader.Dispose() } }
}

function Write-State([string]$Phase) {
    $script:state.phase = $Phase
    $temporary = "$statePath.$PID.tmp"
    [IO.File]::WriteAllText($temporary, ($script:state | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $statePath) {
        # Windows PowerShell 5.1 binds a null backup name as an empty (invalid) path.
        $backup = "$statePath.previous"
        [IO.File]::Replace($temporary, $statePath, $backup)
        [IO.File]::Delete($backup)
    }
    else { [IO.File]::Move($temporary, $statePath) }
}

function Send-Control([string]$Name) {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        $event = $null
        try {
            $event = [Threading.EventWaitHandle]::OpenExisting($Name)
            [void]$event.Set()
            return
        }
        catch [Threading.WaitHandleCannotBeOpenedException] {
            if (-not (Test-Running)) { throw 'Supervisor exited before receiving the command.' }
            Start-Sleep -Milliseconds 100
        }
        finally { if ($null -ne $event) { $event.Dispose() } }
    }
    throw 'Supervisor control channel is unavailable. Try: run.bat stop -Force'
}

function Copy-Log {
    if ($null -ne $script:reader) {
        $chunk = $script:reader.ReadToEnd()
        if ($chunk.Length -gt 0) { [Console]::Write($chunk) }
    }
}

function Stop-Child {
    if ($null -eq $script:job) { return }
    Write-Host '[server] Stopping this server process tree...'
    if ($script:job.ProcessIds().Count -gt 0) {
        if (-not $script:job.HasExited) {
            # AttachConsole changes the caller's console, so signal from a short-lived helper.
            $helper = $null
            try {
                $helperArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" signal -ChildProcessId {1}' -f $scriptPath, $script:job.ProcessId
                $helper = Start-Process -FilePath $windowsPowerShell -ArgumentList $helperArgs -WindowStyle Hidden -PassThru
                if (-not $helper.WaitForExit(3000)) { $helper.Kill() }
            }
            catch { Write-Host "[server] Interrupt unavailable; using job cleanup: $($_.Exception.Message)" }
            finally { if ($null -ne $helper) { $helper.Dispose() } }
        }
        $deadline = [DateTime]::UtcNow.AddSeconds($StopTimeoutSeconds)
        while ($script:job.ProcessIds().Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
            Copy-Log
            Start-Sleep -Milliseconds 100
        }
        if ($script:job.ProcessIds().Count -gt 0) {
            Write-Host '[server] Stop timeout; terminating remaining processes in this server job.'
            $script:job.Terminate()
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while ($script:job.ProcessIds().Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
            if ($script:job.ProcessIds().Count -gt 0) { throw 'Windows has not finished terminating the server job.' }
        }
    }
    Copy-Log
    if ($null -ne $script:reader) { $script:reader.Dispose(); $script:reader = $null }
    $script:job.Dispose()
    $script:job = $null
}

function Find-DartCommand {
    $dartCommand = Get-Command dart -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $dartDirectory = Split-Path -Parent $dartCommand.Source
    $candidates = @(
        (Join-Path $dartDirectory 'dart.exe'),
        (Join-Path $dartDirectory 'cache\dart-sdk\bin\dart.exe')
    )
    $dartExe = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $dartExe) { throw 'Cannot find dart.exe. Add the Flutter or Dart SDK bin directory to PATH.' }
    $cacheCandidates = @()
    if ($env:PUB_CACHE) { $cacheCandidates += $env:PUB_CACHE }
    $frogCommand = Get-Command dart_frog -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($frogCommand) { $cacheCandidates += Split-Path -Parent (Split-Path -Parent $frogCommand.Source) }
    $cacheCandidates += Join-Path $env:LOCALAPPDATA 'Pub\Cache'
    foreach ($cache in $cacheCandidates) {
        $configPath = Join-Path $cache 'global_packages\dart_frog_cli\.dart_tool\package_config.json'
        if (-not (Test-Path -LiteralPath $configPath)) { continue }
        $config = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
        $package = $config.packages | Where-Object name -eq 'dart_frog_cli' | Select-Object -First 1
        if ($null -eq $package) { continue }
        $packageRoot = [Uri]::new([Uri]::new($configPath), [string]$package.rootUri).LocalPath
        $entry = Join-Path $packageRoot 'bin\dart_frog.dart'
        if (Test-Path -LiteralPath $entry) {
            return @{ executable = $dartExe; arguments = @("--packages=$configPath", $entry, 'dev', '--port', "$Port", '--hostname', $Hostname, '--dart-vm-service-port', "$VmServicePort") }
        }
    }
    throw 'dart_frog_cli is not installed. Run: dart pub global activate dart_frog_cli'
}

$script:job = $null
$script:reader = $null
$mutex = $null
$stopEvent = $null
$restartEvent = $null
$ownsMutex = $false
$exitCode = 0
try {
    if ($Action -eq 'signal') {
        if ($ChildProcessId -le 0) { throw 'A child process ID is required.' }
        Import-Native
        [void][SnsServerControl.ServerJob]::InterruptConsole($ChildProcessId)
        exit 0
    }

    if ($Action -eq 'status') {
        if (Test-Running) {
            $current = Read-State
            if ($null -ne $current) {
                Write-Host "[server] $($current.phase) | http://$($current.hostname):$Port | supervisor $($current.supervisorPid), Dart $($current.childPid)"
                Write-Host "[server] Log: $($current.logPath)"
            }
            else { Write-Host "[server] Supervisor is starting on port $Port." }
        }
        else {
            Import-Native
            $listeners = [SnsServerControl.ServerJob]::ListeningProcessIds($Port)
            if ($listeners.Count -gt 0) {
                Write-Host "[server] Unmanaged listener on port $Port (PID $($listeners -join ', ')). Stop it in its original window before starting this manager."
            }
            else { Write-Host "[server] Stopped (port $Port; stale state files are ignored)." }
        }
        exit 0
    }

    if ($Action -eq 'stop' -or $Action -eq 'restart') {
        if (Test-Running) {
            if ($Action -eq 'stop') {
                if ($Force) {
                    Import-Native
                    Send-Control $stopName
                    [void][SnsServerControl.ServerJob]::TerminateOwnedJob($jobName)
                }
                else { Send-Control $stopName }
                $deadline = [DateTime]::UtcNow.AddSeconds($StopTimeoutSeconds + 12)
                while ((Test-Running) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
                if (Test-Running) { throw 'Stop did not complete. Check the supervisor window; retry with stop -Force.' }
                Write-Host '[server] Stopped.'
                exit 0
            }
            $previous = Read-State
            Send-Control $restartName
            $deadline = [DateTime]::UtcNow.AddSeconds($StopTimeoutSeconds + $StartupTimeoutSeconds + 15)
            while ([DateTime]::UtcNow -lt $deadline) {
                if (-not (Test-Running)) { throw 'Restart failed; check the supervisor window and saved log.' }
                $current = Read-State
                if ($null -ne $current -and ($null -eq $previous -or $current.generation -ne $previous.generation) -and $current.phase -eq 'running') {
                    Write-Host "[server] Restarted. Dart PID: $($current.childPid)"
                    exit 0
                }
                Start-Sleep -Milliseconds 200
            }
            throw 'Restart timed out; check the supervisor window and saved log.'
        }
        if ($Action -eq 'stop') {
            Import-Native
            $listeners = [SnsServerControl.ServerJob]::ListeningProcessIds($Port)
            if ($listeners.Count -gt 0) { throw "No managed server; port $Port belongs to an unmanaged process (PID $($listeners -join ', ')). Stop it in its original window. No process was killed." }
            Write-Host '[server] Already stopped.'
            exit 0
        }
        # Restart of a stopped server becomes a foreground start.
    }

    $mutex = [Threading.Mutex]::new($false, $mutexName)
    try { $ownsMutex = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw "This server is already managed on port $Port. Use run.bat restart / stop / status." }
    # A crashed supervisor may leave metadata behind; never display it for this new run.
    if (Test-Path -LiteralPath $statePath) { [IO.File]::Delete($statePath) }
    $stopEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset, $stopName)
    $restartEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset, $restartName)
    Import-Native
    $command = Find-DartCommand
    Set-Location -LiteralPath $root
    # dart_frog gives PORT precedence over --port. Keep both in agreement.
    $env:PORT = "$Port"
    # Child Dart commands resolve the real SDK executable, bypassing Flutter's batch wrapper.
    $env:PATH = (Split-Path -Parent $command.executable) + ';' + $env:PATH
    [void][IO.Directory]::CreateDirectory($runtime)
    Write-Host "[server] $root"
    Write-Host '[server] R: restart | Q / S: stop | or run.bat stop/restart/status in another terminal.'
    Write-Host '[server] Closing this window also terminates the owned server process tree.'

    do {
        $listeners = [SnsServerControl.ServerJob]::ListeningProcessIds($Port)
        if ($listeners.Count -gt 0) { throw "Port $Port is already occupied (PID $($listeners -join ', ')). No unrelated process was stopped." }
        $generation = [Guid]::NewGuid().ToString('N')
        $logPath = Join-Path $runtime ((Get-Date -Format 'yyyyMMdd-HHmmss') + "-$generation.log")
        $script:job = [SnsServerControl.ServerJob]::new($jobName)
        $script:job.Start($command.executable, [string[]]$command.arguments, $root, $logPath)
        $script:reader = [IO.StreamReader]::new([IO.FileStream]::new($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)), [Text.Encoding]::UTF8)
        $script:state = [ordered]@{ phase = 'starting'; supervisorPid = $PID; childPid = $script:job.ProcessId; processIds = @(); hostname = $Hostname; port = $Port; generation = $generation; startedAt = [DateTime]::UtcNow.ToString('o'); logPath = $logPath }
        Write-State 'starting'
        Write-Host "[server] Starting http://${Hostname}:$Port | log: $logPath"
        $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
        $restart = $false
        $ready = $false
        while ($true) {
            Copy-Log
            if ($stopEvent.WaitOne(0)) { break }
            if ($restartEvent.WaitOne(0)) { $restart = $true; break }
            try {
                if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
                    $keyPressed = [Console]::ReadKey($true).Key
                    if ($keyPressed -eq 'R') { $restart = $true; break }
                    if ($keyPressed -eq 'Q' -or $keyPressed -eq 'S') { break }
                }
            }
            catch [InvalidOperationException] { } # No interactive console (scheduled task, etc.).
            if ($script:job.HasExited) { throw "Dart exited with code $($script:job.ExitCode). See the log above." }
            if (-not $ready) {
                $owned = $script:job.ProcessIds()
                $listening = [SnsServerControl.ServerJob]::ListeningProcessIds($Port)
                if (@($listening | Where-Object { $owned -contains $_ }).Count -gt 0) {
                    $ready = $true
                    $script:state.processIds = @($owned)
                    Write-State 'running'
                    Write-Host '[server] Ready.'
                }
                elseif ([DateTime]::UtcNow -ge $deadline) { throw "No owned listener on port $Port within $StartupTimeoutSeconds seconds." }
            }
            Start-Sleep -Milliseconds 100
        }
        Write-State 'stopping'
        Stop-Child
    } while ($restart)
}
catch {
    Write-Host "[server] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    try { Stop-Child }
    catch { Write-Host "[server] Cleanup: $($_.Exception.Message)"; $exitCode = 1 }
    finally {
        if ($null -ne $script:reader) { $script:reader.Dispose() }
        if ($null -ne $script:job) { $script:job.Dispose() }
        if ($ownsMutex) {
            if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath -Force }
            $mutex.ReleaseMutex()
        }
        if ($null -ne $stopEvent) { $stopEvent.Dispose() }
        if ($null -ne $restartEvent) { $restartEvent.Dispose() }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}
exit $exitCode
