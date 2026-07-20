#Requires -Version 5.1
<#
.DESCRIPTION
    Checks, any failure exits 3:
      1. required assemblies load AND their referenced types resolve
      2. service or process is running
      3. Task Scheduler job(s) enabled and last run succeeded
      4. a log directory has a file written recently (liveness)
      5. optional HTTP probe returns the expected status

    Two health profiles, because OMS has two kinds of target:
      - Java/Spring Boot services (VESOMSVEMS01/02, VESMERA01): use -HealthUrl
        against the Actuator endpoint, e.g. http://localhost:9193/actuator/health
        (esr-mover 9193, pagecount 9191/9192, cenl 8181/8182, user-provisioning
        8081, alert-report 9194, MERA cfilemanagement 9090-9099).
      - Outbound .exe processors (VESEMSEGRESS0x): NO actuator endpoint, so prove
        liveness with -ScheduledTasks (Task Scheduler last-run result) plus
        -FreshLogDir (a recent line under C:\VLER_Test\Logs\...). Optionally add a
        DB signal check separately (FTPOutboundStack Ready->Sent on VESSQLOMS101).

    Assembly check applies to .NET targets. PowerBuilder/native targets need a
    LoadLibrary variant instead; hold off until the system list is confirmed.
#>
[CmdletBinding()]
param(
    [string[]]$RequiredAssemblies = @(),
    [string]$ServiceName,
    [string]$ProcessName,
    # Task Scheduler jobs for the outbound processors, e.g.
    # VLER_EM_Real_Time_Outbound_Processor. Healthy = enabled + last run == 0.
    [string[]]$ScheduledTasks = @(),
    # liveness for endpoint-less .exe processors: newest file here must be recent
    [string]$FreshLogDir,
    [int]$FreshLogMaxAgeMinutes = 60,
    [string]$HealthUrl,
    [int]$ExpectedStatus = 200,
    [string]$Processor = 'unknown',
    [string]$CommitSha = 'unknown',
    [string]$LogFile,
    [switch]$Json
)
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'
# every check appends a reason string here; a non-empty list at the end = unhealthy (exit 3)
$fail = New-Object System.Collections.Generic.List[string]

# Check 1: each required .NET assembly loads and its types resolve (catches a missing dependency)
foreach ($dll in $RequiredAssemblies) {
    try {
        if (-not (Test-Path -LiteralPath $dll)) { throw 'file not found' }
        $asm = [System.Reflection.Assembly]::LoadFrom($dll)
        # LoadFrom alone is lazy about references. GetTypes() forces the loader to
        # resolve them now, which is what surfaces a missing transitive dependency.
        [void]$asm.GetTypes()
        Write-VesLog OK "Assembly OK: $([IO.Path]::GetFileName($dll))" -LogFile $LogFile
    } catch [System.Reflection.ReflectionTypeLoadException] {
        # LoaderExceptions names the actual missing assembly
        $inner = ($_.Exception.LoaderExceptions | ForEach-Object { $_.Message }) -join '; '
        $fail.Add("assembly:$dll -> $inner")
        Write-VesLog ERROR "Assembly LOAD FAIL (missing dep): $dll -> $inner" -LogFile $LogFile
    } catch {
        $fail.Add("assembly:$dll -> $($_.Exception.Message)")
        Write-VesLog ERROR "Assembly LOAD FAIL: $dll -> $($_.Exception.Message)" -LogFile $LogFile
    }
}

# Check 2: liveness by Windows service state (Java services) or, failing that, a running process
if ($ServiceName) {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') {
        $fail.Add("service:$ServiceName not running")
        Write-VesLog ERROR "Service DOWN: $ServiceName" -LogFile $LogFile
    } else { Write-VesLog OK "Service running: $ServiceName" -LogFile $LogFile }
}
elseif ($ProcessName) {
    if (-not (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        $fail.Add("process:$ProcessName not found")
        Write-VesLog ERROR "Process DOWN: $ProcessName" -LogFile $LogFile
    } else { Write-VesLog OK "Process running: $ProcessName" -LogFile $LogFile }
}

# Task Scheduler jobs: the outbound processors run as scheduled tasks, so their
# health is the job's last-run result, not a service state or an HTTP endpoint.
foreach ($tn in $ScheduledTasks) {
    try {
        $task = Get-ScheduledTask -TaskName $tn -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $tn -ErrorAction Stop
        $lr   = $info.LastTaskResult
        if ($task.State -eq 'Disabled') {
            $fail.Add("task:$tn disabled"); Write-VesLog ERROR "Task DISABLED: $tn" -LogFile $LogFile
        }
        elseif ($lr -eq 0) {
            Write-VesLog OK "Task OK: $tn (last result 0)" -LogFile $LogFile
        }
        elseif ($lr -eq 267009) {   # 0x41301 = currently running
            Write-VesLog OK "Task running: $tn" -LogFile $LogFile
        }
        else {
            # 267011/0x41303 = has not run yet; anything non-zero is a failed/odd run
            $fail.Add("task:$tn lastresult=$lr")
            Write-VesLog ERROR ("Task last run not OK: {0} (result 0x{1:X})" -f $tn, $lr) -LogFile $LogFile
        }
    } catch {
        $fail.Add("task:$tn not found")
        Write-VesLog ERROR "Task not found: $tn -> $($_.Exception.Message)" -LogFile $LogFile
    }
}

# Fresh-log liveness: an endpoint-less processor proves it is alive by writing to
# its log. Newest file in the dir must be younger than the threshold.
if ($FreshLogDir) {
    if (-not (Test-Path -LiteralPath $FreshLogDir)) {
        $fail.Add("logdir:$FreshLogDir missing")
        Write-VesLog ERROR "Log dir missing: $FreshLogDir" -LogFile $LogFile
    } else {
        $newest = Get-ChildItem -LiteralPath $FreshLogDir -File -Recurse -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $newest) {
            $fail.Add("logdir:$FreshLogDir empty")
            Write-VesLog ERROR "No log files under: $FreshLogDir" -LogFile $LogFile
        } else {
            $ageMin = [int]((Get-Date) - $newest.LastWriteTime).TotalMinutes
            if ($ageMin -gt $FreshLogMaxAgeMinutes) {
                $fail.Add("log stale: $($newest.Name) ${ageMin}min")
                Write-VesLog ERROR "Log stale: $($newest.Name) is ${ageMin}min old (max $FreshLogMaxAgeMinutes)" -LogFile $LogFile
            } else {
                Write-VesLog OK "Fresh log: $($newest.Name) (${ageMin}min old)" -LogFile $LogFile
            }
        }
    }
}

# Check 5 (optional): HTTP probe for Java/Spring Boot actuator endpoints
if ($HealthUrl) {
    try {
        # UseBasicParsing avoids the IE dependency on server core
        $resp = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 15
        if ($resp.StatusCode -ne $ExpectedStatus) {
            $fail.Add("endpoint:$HealthUrl -> $($resp.StatusCode)")
            Write-VesLog ERROR "Endpoint bad status: $($resp.StatusCode)" -LogFile $LogFile
        } else { Write-VesLog OK "Endpoint OK: $HealthUrl" -LogFile $LogFile }
    } catch {
        $fail.Add("endpoint:$HealthUrl -> $($_.Exception.Message)")
        Write-VesLog ERROR "Endpoint FAIL: $($_.Exception.Message)" -LogFile $LogFile
    }
}

# healthy only if no check added a failure; summarize, optionally emit JSON, exit 0 or 3
$healthy = ($fail.Count -eq 0)
if (-not $healthy) {
    Write-VesLog ERROR "HEALTH FAIL $Processor -> $($fail -join ' | ')" -LogFile $LogFile
}

# --- Datadog: health results as gauges (non-fatal) --------------------------
# The outbound .exe processors have no endpoint of their own, so this gauge is
# the only way their liveness reaches a dashboard. Low-cardinality tags only.
$ddTags = @("processor:$Processor", (Get-VesDatadogEnvTag), "check:health")
# 1 = all requested checks passed; 0 = at least one failed.
Send-VesDatadogMetric -Metric 'deployment.health.status'   -Value ([int]$healthy) -Tags $ddTags
# Failure count gives severity at a glance without per-check tag cardinality.
Send-VesDatadogMetric -Metric 'deployment.health.failures' -Value $fail.Count     -Tags $ddTags

if ($Json) {
    # commit included for traceability (which build this liveness result belongs to);
    # kept out of the Datadog tags above on purpose to avoid per-commit cardinality.
    [PSCustomObject]@{ processor=$Processor; commit=$CommitSha; healthy=$healthy; failures=@($fail) } | ConvertTo-Json -Compress
}
Write-VesLog ($(if ($healthy){'OK'}else{'ERROR'})) ("Health check {0}" -f $(if ($healthy){'PASS'}else{'FAIL'})) `
    -Data @{ processor=$Processor; commit=$CommitSha } -LogFile $LogFile
exit ($(if ($healthy) { $VES_EXIT_OK } else { $VES_EXIT_HEALTH }))