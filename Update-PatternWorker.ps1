#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$PythonExe,
    [string]$TaskPath = '\',
    [ValidateRange(30, 7200)][int]$IdleWaitSeconds = 900,
    [ValidateRange(30, 3600)][int]$VerifySeconds = 600,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pin this package to the captured Nov 23 worker and the reviewed update.
$baselineHash = '6c6f968054f7a08d83a4011f862189ee79402fc219a2b79f5d6e48f8beebfce5'
$targetHash = 'a8ca1e9152b8cc36fc9271559382075a11d0829375b9bb10ebad4698bf05863e'
$deltaHash = '17edfb5cace5031dc54af0ed3de1f2ffa9d37d0e41a235a679979c21272835d3'
$applierHash = '7bb739c8a80790d8b27cf530ef79763ca9c76c55e1069ffd9ee5526e101e4cad'
$probeHash = 'c9004cb0368df9fdd6edb3f03a7111c8a142bdb807707407cb189c0a816cacea'
$taskName = 'AIHelper Stage 5 AI Worker'
$deltaPath = Join-Path $PSScriptRoot 'pattern-delta.json'
$applierPath = Join-Path $PSScriptRoot 'apply_delta.py'
$probePath = Join-Path $PSScriptRoot 'probe_worker.py'
$phase = 'preflight'
$taskDisabled = $false
$taskStopped = $false
$replaced = $false
$backup = $null
$stage = $null
$lock = $null
$wasRunning = $false

function Assert-Hash([string]$Path, [string]$Expected, [string]$Code) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw $Code }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected) { throw $Code }
}

function Get-WorkerTask {
    try {
        $matches = @(Get-ScheduledTask -TaskName $taskName -ErrorAction Stop |
            Where-Object { $_.TaskPath -eq $TaskPath })
    } catch {
        throw 'worker_task_lookup_failed'
    }
    if ($matches.Count -ne 1) { throw 'worker_task_not_unique' }
    return $matches[0]
}

function Invoke-Probe([string]$Since) {
    $lines = @(& $script:python -B $probePath --root $script:root --since $Since 2>$null)
    if ($LASTEXITCODE -ne 0 -or $lines.Count -lt 1) { throw 'read_only_probe_unavailable' }
    try {
        $value = $lines[-1] | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $value.active_leases -or $null -eq $value.completed_pattern_since -or
            $null -eq $value.heartbeat) {
            throw 'probe_fields_missing'
        }
        return $value
    } catch {
        throw 'read_only_probe_invalid'
    }
}

function Get-WorkerProcessCount {
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" |
        Where-Object {
            $_.ExecutablePath -eq $script:launcherExe -and
            $_.CommandLine -match '(?i)\brun_stage5_worker\.py\b' -and
            $_.CommandLine -match '(?i)(?:^|\s)"?ai"?(?:\s|$)'
        })
    return $processes.Count
}

function Test-FreshHeartbeat($Heartbeat, [datetimeoffset]$Since) {
    if ($null -eq $Heartbeat -or -not $Heartbeat.last_seen_at) { return $false }
    try {
        $seen = [datetimeoffset]::Parse($Heartbeat.last_seen_at)
        return $seen -ge $Since
    } catch {
        return $false
    }
}

function Wait-Idle([datetime]$Deadline, [string]$Since, [switch]$AllowRetryMode) {
    $stable = 0
    $idleModes = @('waiting_for_work', 'waiting_for_shift')
    if ($AllowRetryMode) { $idleModes += 'waiting_to_retry' }
    while ([datetime]::UtcNow -lt $Deadline) {
        $snapshot = Invoke-Probe $Since
        $state = (Get-WorkerTask).State.ToString()
        if ([int]$snapshot.active_leases -eq 0) {
            if ($state -ne 'Running' -and (Get-WorkerProcessCount) -eq 0) { return $snapshot }
            $heartbeat = $snapshot.heartbeat
            $fresh = Test-FreshHeartbeat $heartbeat ([datetimeoffset]::UtcNow.AddSeconds(-120))
            if ($fresh -and $heartbeat.mode -in $idleModes) {
                $stable++
                if ($stable -ge 2) { return $snapshot }
            } elseif ($AllowRetryMode -and -not $fresh) {
                # A failed worker may no longer publish heartbeats. Three
                # independent zero-lease reads permit an eventual rollback.
                $stable++
                if ($stable -ge 3) { return $snapshot }
            } else {
                $stable = 0
            }
        } else {
            $stable = 0
        }
        Start-Sleep -Seconds 3
    }
    throw 'worker_idle_window_timeout'
}

function Wait-TaskExit([datetime]$Deadline) {
    while ([datetime]::UtcNow -lt $Deadline) {
        if ((Get-WorkerTask).State.ToString() -ne 'Running' -and
            (Get-WorkerProcessCount) -eq 0) { return }
        Start-Sleep -Seconds 2
    }
    throw 'worker_task_stop_timeout'
}

function Start-OnlyWorker([switch]$ForceStart) {
    if ($script:taskDisabled) {
        Enable-ScheduledTask -InputObject $script:task | Out-Null
        $script:taskDisabled = $false
    }
    if ($script:wasRunning -or $ForceStart) {
        Start-ScheduledTask -InputObject $script:task
        $script:taskStopped = $false
    }
}

try {
    Assert-Hash $deltaPath $deltaHash 'delta_package_hash_mismatch'
    Assert-Hash $applierPath $applierHash 'applier_package_hash_mismatch'
    Assert-Hash $probePath $probeHash 'probe_package_hash_mismatch'
    $task = Get-WorkerTask
    if ($task.State.ToString() -notin @('Running', 'Ready')) { throw 'worker_task_not_enabled' }
    $wasRunning = $task.State.ToString() -eq 'Running'
    $actions = @($task.Actions)
    if ($actions.Count -ne 1 -or $actions[0].Arguments -notmatch '(?i)\brun_stage5_worker\.py\b' -or
        $actions[0].Arguments -notmatch '(?i)(?:^|\s)"?ai"?(?:\s|$)') {
        throw 'unexpected_worker_task_action'
    }
    $launcherExe = ([string]$actions[0].Execute).Trim('"')
    if ((Split-Path $launcherExe -Leaf) -notin @('python.exe', 'pythonw.exe') -or
        -not (Test-Path -LiteralPath $launcherExe -PathType Leaf)) {
        throw 'unexpected_worker_task_executable'
    }
    $launcherExe = (Resolve-Path -LiteralPath $launcherExe).Path

    $arguments = [string]$actions[0].Arguments
    $launcherArgument = [regex]::Match($arguments,
        '(?i)(?:"(?<quoted>[^\"]*run_stage5_worker\.py)"|(?<plain>\S*run_stage5_worker\.py))\s+"?ai"?(?:\s|$)')
    if (-not $launcherArgument.Success) { throw 'worker_launcher_argument_unrecognized' }
    $scriptArg = $launcherArgument.Groups['quoted'].Value
    if (-not $scriptArg) { $scriptArg = $launcherArgument.Groups['plain'].Value }
    if ([IO.Path]::IsPathRooted($scriptArg)) {
        $actionLauncher = [IO.Path]::GetFullPath($scriptArg)
    } else {
        $working = [Environment]::ExpandEnvironmentVariables(([string]$actions[0].WorkingDirectory).Trim('"'))
        if (-not $working) { throw 'task_working_directory_required' }
        $actionLauncher = [IO.Path]::GetFullPath((Join-Path $working $scriptArg))
    }
    $actionRuntime = Split-Path $actionLauncher -Parent
    if ((Split-Path $actionRuntime -Leaf) -ne '.runtime') {
        throw 'task_launcher_outside_runtime'
    }
    $taskRoot = Split-Path $actionRuntime -Parent
    if ($InstallRoot) {
        $root = (Resolve-Path -LiteralPath $InstallRoot).Path
        if ([IO.Path]::GetFullPath($root).TrimEnd('\') -ne
            [IO.Path]::GetFullPath($taskRoot).TrimEnd('\')) {
            throw 'install_root_does_not_match_task'
        }
    } else {
        $root = (Resolve-Path -LiteralPath $taskRoot).Path
    }
    $runtime = Join-Path $root '.runtime'
    $installed = Join-Path $runtime 'stage5_shift_ai.py'
    if ([IO.Path]::GetFullPath($actionLauncher) -ne
        [IO.Path]::GetFullPath((Join-Path $runtime 'run_stage5_worker.py')) -or
        -not (Test-Path -LiteralPath $actionLauncher) -or
        -not (Test-Path -LiteralPath (Join-Path $root 'app-source\ai_worker\patterns.py'))) {
        throw 'installed_dependencies_missing'
    }

    if (-not $PythonExe) { $PythonExe = $launcherExe }
    if (-not $PythonExe -or (Split-Path $PythonExe -Leaf) -notmatch '^python(?:3(?:\.\d+)?)?\.exe$' -or
        -not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) {
        throw 'installed_python_exe_required'
    }
    $python = (Resolve-Path -LiteralPath $PythonExe).Path
    if ((Split-Path $python -Parent) -ne (Split-Path $launcherExe -Parent)) {
        throw 'python_environment_does_not_match_task'
    }
    $installedHash = (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($installedHash -eq $targetHash) {
        Write-Output 'already_installed_target_hash'
        return
    }
    if ($installedHash -ne $baselineHash) { throw 'installed_worker_drift_review_required' }

    $since = [datetimeoffset]::UtcNow.ToString('o')
    $preflight = Invoke-Probe $since
    if (-not $Apply) {
        Write-Output ('preflight_ok active_leases=' + $preflight.active_leases +
            ' task_state=' + $task.State.ToString() + ' apply=false')
        return
    }

    $phase = 'stage'
    $lockPath = Join-Path $runtime '.pattern-update.lock'
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
                            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $stage = Join-Path $runtime ('stage5_shift_ai.py.stage-' + [guid]::NewGuid().ToString('N'))
    & $python -B $applierPath --source $installed --delta $deltaPath --output $stage `
        --baseline-sha256 $baselineHash --target-sha256 $targetHash | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'delta_apply_failed' }
    Assert-Hash $stage $targetHash 'staged_hash_mismatch'
    $compileCode = 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); compile(p.read_text(encoding="utf-8"),str(p),"exec")'
    & $python -B -c $compileCode $stage | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'staged_python_syntax_invalid' }
    $backupDir = Join-Path $runtime 'backups'
    [IO.Directory]::CreateDirectory($backupDir) | Out-Null
    $backup = Join-Path $backupDir ('stage5_shift_ai.before-pattern-' +
        [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.py')
    [IO.File]::Copy($installed, $backup, $false)
    Assert-Hash $backup $baselineHash 'backup_hash_mismatch'

    $phase = 'quiesce'
    $deadline = [datetime]::UtcNow.AddSeconds($IdleWaitSeconds)
    Wait-Idle $deadline $since | Out-Null
    Disable-ScheduledTask -InputObject $task | Out-Null
    $taskDisabled = $true
    if ((Get-WorkerTask).State.ToString() -eq 'Running' -or
        (Get-WorkerProcessCount) -gt 0) {
        # Poll once more after disabling the trigger. A very small claim/stop
        # race remains until the old worker supports a quiesce handshake.
        $last = Invoke-Probe $since
        if ([int]$last.active_leases -ne 0) { throw 'worker_claimed_during_quiesce' }
        Stop-ScheduledTask -InputObject $task
        $taskStopped = $true
        Wait-TaskExit ([datetime]::UtcNow.AddSeconds(60))
    }
    if ((Get-WorkerProcessCount) -ne 0) { throw 'worker_process_still_running' }
    $last = Invoke-Probe $since
    if ([int]$last.active_leases -ne 0) { throw 'worker_lease_after_stop' }
    Assert-Hash $installed $baselineHash 'installed_worker_changed_during_quiesce'

    $phase = 'replace'
    [IO.File]::Replace($stage, $installed, $null, $true)
    $stage = $null
    $replaced = $true
    Assert-Hash $installed $targetHash 'installed_target_hash_mismatch'
    $phase = 'restart'
    Start-OnlyWorker -ForceStart

    $phase = 'verify'
    $verifyDeadline = [datetime]::UtcNow.AddSeconds($VerifySeconds)
    $startedAt = [datetimeoffset]::UtcNow.AddSeconds(-5)
    $patternVerified = $false
    $scanCount = 0
    while ([datetime]::UtcNow -lt $verifyDeadline) {
        if ((Get-WorkerTask).State.ToString() -ne 'Running') {
            Start-Sleep -Seconds 5
            continue
        }
        $snapshot = Invoke-Probe $since
        $scanCount = [int]$snapshot.completed_pattern_since
        $heartbeat = $snapshot.heartbeat
        if ((Test-FreshHeartbeat $heartbeat $startedAt) -and
            $heartbeat.pattern_pipeline_enabled -eq $true -and
            $heartbeat.status -in @('ok', 'working') -and
            $heartbeat.pattern_discovery -in @('checked', 'scheduled_later') -and
            $heartbeat.pattern_last_result -notin @('error', 'discovery_error', 'not_checked')) {
            $patternVerified = $true
            break
        }
        Start-Sleep -Seconds 5
    }
    if ((Get-WorkerTask).State.ToString() -ne 'Running') { throw 'worker_not_running_after_restart' }
    $snapshot = Invoke-Probe $since
    $heartbeat = $snapshot.heartbeat
    $scanCount = [int]$snapshot.completed_pattern_since
    if (-not (Test-FreshHeartbeat $heartbeat ([datetimeoffset]::UtcNow.AddSeconds(-120))) -or
        $heartbeat.status -notin @('ok', 'working')) {
        throw 'fresh_worker_heartbeat_not_verified'
    }
    $verification = if ($patternVerified) { 'pattern_pipeline_confirmed' }
                    else { 'worker_running_pattern_check_pending' }
    Write-Output ('update_verified status=' + $verification + ' target_sha256=' + $targetHash +
        ' pattern_jobs_done_since_update_global=' + $scanCount +
        ' pattern_last_result=' + $heartbeat.pattern_last_result +
        ' backup_path=' + $backup)
} catch {
    $failedPhase = $phase
    $failureCode = $_.Exception.Message
    if ($failureCode -notmatch '^[a-z0-9_]+$') { $failureCode = 'operation_failed' }
    $rollback = 'not_needed'
    try {
        if ($replaced) {
            $rollback = 'started'
            # Never interrupt a newly leased scan merely to satisfy a timeout.
            Wait-Idle ([datetime]::UtcNow.AddSeconds($IdleWaitSeconds)) $since -AllowRetryMode | Out-Null
            if (-not $taskDisabled) {
                Disable-ScheduledTask -InputObject $task | Out-Null
                $taskDisabled = $true
            }
            if ((Get-WorkerTask).State.ToString() -eq 'Running' -or
                (Get-WorkerProcessCount) -gt 0) {
                Stop-ScheduledTask -InputObject $task
                Wait-TaskExit ([datetime]::UtcNow.AddSeconds(60))
            }
            if ([int](Invoke-Probe $since).active_leases -ne 0) { throw 'rollback_lease_active' }
            $restore = Join-Path $runtime ('stage5_shift_ai.py.restore-' + [guid]::NewGuid().ToString('N'))
            [IO.File]::Copy($backup, $restore, $false)
            Assert-Hash $restore $baselineHash 'rollback_copy_hash_mismatch'
            [IO.File]::Replace($restore, $installed, $null, $true)
            Assert-Hash $installed $baselineHash 'rollback_hash_mismatch'
            Start-OnlyWorker
            $rollback = 'restored_baseline_and_worker_started'
        } elseif ($taskDisabled) {
            Start-OnlyWorker
            $rollback = 'worker_task_restored'
        }
    } catch {
        $rollback = 'incomplete_backup_preserved'
        # Best effort: never leave the scheduled AI worker disabled.
        if ($taskDisabled) {
            try { Start-OnlyWorker } catch { }
        }
    }
    throw ('pattern_update_failed phase=' + $failedPhase + ' reason=' + $failureCode +
        ' rollback=' + $rollback)
} finally {
    if ($null -ne $stage -and (Test-Path -LiteralPath $stage)) {
        Remove-Item -LiteralPath $stage -Force
    }
    if ($null -ne $lock) { $lock.Dispose() }
}
