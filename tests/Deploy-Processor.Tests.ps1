#Requires -Version 5.1
# Deploy-Processor.ps1 end-to-end: gate -> copy -> verify -> health, plus the
# console-EXE instance handling. SSM is stubbed with a fake aws.cmd on PATH.
# The "running instance" is a real process: powershell.exe copied INTO the
# target dir and started there, so its ExecutablePath sits under TargetRoot
# exactly like a deployed processor exe. No scheduled tasks or services used.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')

    $script:Root         = Join-Path $TestDrive 'dp'
    $script:Release      = New-VesTree (Join-Path $script:Root 'release')
    $script:Staged       = New-VesTree (Join-Path $script:Root 'staged')   # identical tree = same manifest hash
    $script:ManifestPath = Join-Path $script:Root 'baseline.json'
    $script:HealthAssembly = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\System.dll'

    $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
        '-Mode','Capture','-ReleaseRoot',$script:Release,
        '-ManifestPath',$script:ManifestPath,'-Processor','dptest',
        '-AllowUntrustedCapture','-AllowUnarchivedCapture')
    if ($cap.ExitCode -ne 0) { throw "baseline capture failed: $($cap.Output)" }
    $script:TrustedHash = (Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json).manifestHash

    $script:StubDir = Join-Path $TestDrive 'awsstub-dp'
    New-Item -ItemType Directory -Path $script:StubDir -Force | Out-Null
    @(
        '@echo off'
        'if "%~4"=="/ves/dptest/approved-commit" echo abc1234& exit /b 0'
        ('if "%~4"=="/ves/dptest/baseline-hash" echo {0}& exit /b 0' -f $script:TrustedHash)
        'echo An error occurred (ParameterNotFound) 1>&2'
        'exit /b 254'
    ) | Set-Content -Path (Join-Path $script:StubDir 'aws.cmd') -Encoding ascii
    $script:OrigPath = $env:PATH
    $env:PATH = "$($script:StubDir);$env:PATH"

    function script:New-DeployArgs([string]$TargetRoot, [string[]]$Extra = @()) {
        @(
            '-Processor','dptest',
            '-StagedRoot',$script:Staged,
            '-TargetRoot',$TargetRoot,
            '-StagedCommit','abc1234',
            '-ManifestPath',$script:ManifestPath,
            '-TrustParam','/ves/dptest/baseline-hash',
            '-ApprovedCommitParam','/ves/dptest/approved-commit',
            '-RequiredAssemblies',$script:HealthAssembly
        ) + $Extra
    }

    # start a long-lived process whose exe lives under $TargetRoot
    function script:Start-LockedInstance([string]$TargetRoot) {
        New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
        $exe = Join-Path $TargetRoot 'locked-instance.exe'
        Copy-Item -LiteralPath (Get-WinPowerShellPath) -Destination $exe -Force
        Start-Process -FilePath $exe -ArgumentList '-NoProfile','-Command','Start-Sleep 300' -WindowStyle Hidden -PassThru
    }
}

AfterAll { $env:PATH = $script:OrigPath }

Describe 'clean deploy' {
    It 'runs gate -> copy -> verify -> health and exits 0' {
        $target = Join-Path $script:Root 'target-clean'
        $r = Invoke-VesScript 'Deploy-Processor.ps1' (New-DeployArgs $target)
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'DEPLOY COMPLETE'
        Test-Path (Join-Path $target 'bin\lib.dll') | Should -BeTrue
    }

    It 'gate-only with -WhatIf, target untouched' {
        $target = Join-Path $script:Root 'target-whatif'
        $r = Invoke-VesScript 'Deploy-Processor.ps1' (New-DeployArgs $target @('-WhatIf'))
        $r.ExitCode | Should -Be 0
        Test-Path $target | Should -BeFalse
    }

    It 'blocks before copy when the staged config is missing' {
        $target = Join-Path $script:Root 'target-missing-config'
        $r = Invoke-VesScript 'Deploy-Processor.ps1' (New-DeployArgs $target @(
            '-ConfigContract',(Join-Path $PSScriptRoot 'fixtures\json\contract.json'),
            '-ConfigPath',(Join-Path $target 'app.exe.config')))
        $r.ExitCode | Should -Be 1
        $r.Output   | Should -Match 'app\.exe\.config is missing from the artifact'
        Test-Path $target | Should -BeFalse
    }
}

Describe 'running console-EXE instance' {
    AfterEach {
        # never leave a sleeper behind, even when an assertion failed
        if ($script:LockProc -and -not $script:LockProc.HasExited) {
            Stop-Process -Id $script:LockProc.Id -Force -ErrorAction SilentlyContinue
        }
        $script:LockProc = $null
    }

    It 'aborts (state restored, no copy) when an instance holds the target and -KillProcesses is not set' {
        $target = Join-Path $script:Root 'target-locked'
        $script:LockProc = Start-LockedInstance $target
        $r = Invoke-VesScript 'Deploy-Processor.ps1' (New-DeployArgs $target)
        $r.ExitCode | Should -Be 1
        $r.Output   | Should -Match 'Running instance holds'
        $r.Output   | Should -Match '-KillProcesses'
        # no copy happened: the staged files never landed
        Test-Path (Join-Path $target 'bin\lib.dll') | Should -BeFalse
        # and the instance was left alone
        $script:LockProc.HasExited | Should -BeFalse
    }

    It 'kills the instance (audited) and deploys when -KillProcesses is set' {
        $target = Join-Path $script:Root 'target-kill'
        $script:LockProc = Start-LockedInstance $target
        $r = Invoke-VesScript 'Deploy-Processor.ps1' (New-DeployArgs $target @('-KillProcesses'))
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match ('Killing running instance PID {0}' -f $script:LockProc.Id)
        $r.Output   | Should -Match 'DEPLOY COMPLETE'
        $script:LockProc.HasExited | Should -BeTrue
        # /MIR removed the foreign exe and the staged tree is in place
        Test-Path (Join-Path $target 'locked-instance.exe') | Should -BeFalse
        Test-Path (Join-Path $target 'bin\lib.dll')         | Should -BeTrue
    }
}
