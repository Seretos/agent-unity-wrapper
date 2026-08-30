#Requires -Version 5.1
<#
.SYNOPSIS
  Pester 3.x driving tests for ticket #47 R1/R2/R9: adopting a Hub-started
  Unity editor for the current checkout (via $puw_launchScript's -AdoptOnly
  mode, materialized from scripts\prepare-unity-worktree.ps1), and the
  SessionStart hook that invokes it automatically on Claude Code.

  Run with:  Invoke-Pester .\tests\unity-mcp-adopt.Tests.ps1 -Verbose

.NOTES
  Environment caveat discovered while writing these tests: this sandbox's
  Windows account has neither Administrator rights nor Developer Mode enabled
  (no SeCreateSymbolicLinkPrivilege), so `New-Item -ItemType SymbolicLink`
  fails here with "Administrator privilege required for this operation."
  Tests whose FIXTURE setup needs a real pre-existing symlink (the dangling-
  link case) detect this once via $global:uma_symlinkCapable and, when
  unsupported, skip only the real-fixture assertions with a Write-Warning -
  the structural + behavioural-replica assertions alongside them are what
  actually proves the RED/GREEN transition and do not depend on this
  privilege. This does not affect the RED evidence recorded in phase=tests:
  every test below is currently RED because scripts\prepare-unity-worktree.ps1
  has no $launchScript here-string and hooks\ does not exist yet, independent
  of symlink privilege.

  Test-critic round 1 fix: the decision of which instance to adopt (and, for
  R3/R4 in tests\prepare-unity-worktree.Tests.ps1, the launcher's three-branch
  decision and the Library-mirror same-path guard) must be a pure,
  dot-sourceable function inside $launchScript, separate from the
  side-effecting symlink-creation call. This file now dot-sources
  $launchScript's materialized source (". $path", not "& $path") wherever it
  needs to call one of these functions directly or Mock a side-effecting one:
    - Find-AdoptionCandidate -CheckoutPath -GlobalStatusDir [-HeartbeatMaxAgeSeconds] [-PortProbeTimeoutMs]
        -> $null, or @{ StatusFile = <path>; PortFile = <path> } for the live match.
    - New-AdoptionSymlink -LinkPath -Target
        -> side-effecting; wraps New-Item -ItemType SymbolicLink. Mocked below
           to simulate an access-denied failure without needing real privilege.
    - Remove-StaleAdoptionLinks -StatusDir
        -> deletes every reparse-point/symlink entry in StatusDir unconditionally;
           leaves real files untouched.
    - Invoke-UnityMcpAdoption -CheckoutPath -GlobalStatusDir [...]
        -> the preamble: ensures <CheckoutPath>/.unity-mcp exists, calls
           Remove-StaleAdoptionLinks, calls Find-AdoptionCandidate, and on a
           match calls New-AdoptionSymlink for both files. Re-throws with the
           Developer-Mode remedy text if New-AdoptionSymlink is denied.
  These names are this developer's assumed contract for the phase=implement
  script, invented to satisfy the test-critic's "call the real function, not a
  replica" requirement; they are not yet defined anywhere, which is exactly
  today's RED (CommandNotFoundException on first call).
#>

$global:uma_repoRoot   = Split-Path -Parent $PSScriptRoot
$global:uma_scriptPath = Join-Path $global:uma_repoRoot 'scripts\prepare-unity-worktree.ps1'

# ---------------------------------------------------------------------------
# Named here-string extractor - duplicated from prepare-unity-worktree.Tests.ps1
# so this file has no cross-file load-order dependency. See that file's header
# comment for why the extractor must be NAMED (ticket #47 plan-critic fix).
# ---------------------------------------------------------------------------
function Get-NamedHereStrings {
    param([string]$Path)
    $lines   = [System.IO.File]::ReadAllLines($Path)
    $result  = @{}
    $current = $null
    $buffer  = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        $t = $line.TrimEnd()
        if ($null -eq $current -and $t -match '^\s*\$(\w+)\s*=\s*@''$') {
            $current = $Matches[1]
            $buffer  = [System.Collections.Generic.List[string]]::new()
            continue
        }
        if ($null -ne $current -and $t -eq "'@") {
            $result[$current] = ($buffer -join "`n")
            $current = $null
            continue
        }
        if ($null -ne $current) { $buffer.Add($t) }
    }
    return $result
}

$global:uma_hereStrings     = Get-NamedHereStrings -Path $global:uma_scriptPath
$global:uma_launchScriptSrc = $global:uma_hereStrings['launchScript']

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function New-TempDir {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("uma-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    return $tmp
}
function Remove-TempDir { param($p) Remove-Item -Recurse -Force -Path $p -ErrorAction SilentlyContinue }
function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# Materializes $puw_launchScript's source into a standalone temp .ps1 file so
# it can be invoked directly with -AdoptOnly / -CheckoutPath / -GlobalStatusDir.
# Currently the here-string does not exist yet (ticket #47 not implemented),
# so this writes a placeholder comment; invoking it will fail to bind the
# expected parameters, which IS the expected RED for R1/R2 below.
function New-MaterializedLaunchScript {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("uma-launch-" + [System.IO.Path]::GetRandomFileName() + '.ps1')
    $src = $global:uma_launchScriptSrc
    if ([string]::IsNullOrEmpty($src)) {
        $src = '# launchScript here-string not found in prepare-unity-worktree.ps1 (ticket #47 not yet implemented)'
    }
    Write-Utf8NoBom -Path $tmp -Content $src
    return $tmp
}

function New-StatusFixture {
    param(
        [string]$GlobalStatusDir,
        [string]$ProjectPath,
        [int]$Port,
        [int]$HeartbeatAgeSeconds = 5,
        [string]$NamePrefix = 'unity-mcp'
    )
    New-Item -ItemType Directory -Force -Path $GlobalStatusDir | Out-Null
    $heartbeat = (Get-Date).ToUniversalTime().AddSeconds(-$HeartbeatAgeSeconds).ToString('o')
    # Field names verified against the real mcpforunityserver==9.7.1 wheel
    # (review round 3): unity_port / last_heartbeat, not port / heartbeat -
    # see scripts\prepare-unity-worktree.ps1's Get-StatusFileHeartbeatAgeSeconds
    # header comment for the exact upstream source lines.
    $statusObj = [pscustomobject]@{
        project_path = $ProjectPath
        unity_port   = $Port
        last_heartbeat = $heartbeat
    }
    $statusFile = Join-Path $GlobalStatusDir "$NamePrefix-status-$Port.json"
    $portFile   = Join-Path $GlobalStatusDir "$NamePrefix-port-$Port.json"
    ($statusObj | ConvertTo-Json) | Set-Content -Path $statusFile -Encoding UTF8
    (@{ unity_port = $Port } | ConvertTo-Json) | Set-Content -Path $portFile -Encoding UTF8
    return @{ StatusFile = $statusFile; PortFile = $portFile }
}

function Start-FakeUnityListener {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    return @{ Listener = $listener; Port = $port }
}
function Stop-FakeUnityListener { param($h) if ($h -and $h.Listener) { try { $h.Listener.Stop() } catch { } } }

# Probe once whether this environment can create filesystem symlinks (see
# .NOTES above). Only fixture setup for the dangling-link scenario needs this.
$global:uma_symlinkCapable = $false
try {
    $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("uma-probe-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $probeDir | Out-Null
    $probeTarget = Join-Path $probeDir 't.txt'
    Set-Content -Path $probeTarget -Value 'x'
    $probeLink = Join-Path $probeDir 'l.txt'
    New-Item -ItemType SymbolicLink -Path $probeLink -Target $probeTarget -ErrorAction Stop | Out-Null
    $global:uma_symlinkCapable = $true
} catch {
    $global:uma_symlinkCapable = $false
} finally {
    Remove-Item -Recurse -Force $probeDir -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# R1 — a Hub-started editor for this checkout is adopted, from either entry
# point.
# ---------------------------------------------------------------------------
Describe 'unity-mcp-launch.ps1 -AdoptOnly - adopts a Hub-started editor for this checkout (ticket #47 / R1)' {

    It 'symlinks the matching status and port file into <checkout>/.unity-mcp, and nothing else' {
        # Gated the same way the file's other real-fixture (unmocked) tests
        # already are (see the R2 "dangling symlink" test below and file
        # header .NOTES): this test drives a REAL, unmocked & $launchScript
        # invocation, which calls New-AdoptionSymlink -> New-Item -ItemType
        # SymbolicLink for real. Without Developer Mode/admin that throws
        # inside Invoke-UnityMcpAdoption's "fail loudly" path (correct
        # behaviour per the plan) before this test ever reaches its own
        # assertions, surfacing as an uncaught exception rather than a test
        # failure. Skip the same way the file's other gated tests do; the
        # Mocked "fails loudly" test later in this Describe already proves the
        # denied-symlink behaviour without needing real privilege.
        if (-not $global:uma_symlinkCapable) {
            Write-Warning 'symlink creation unsupported in this sandbox (no Developer Mode / admin) - skipping this real-fixture test; see file header .NOTES.'
            return
        }
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $fake = Start-FakeUnityListener
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port -HeartbeatAgeSeconds 5 | Out-Null
            # decoy: a live-looking status file for a DIFFERENT project - must not be touched.
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath 'C:\some\other\project\Assets' -Port 12345 -HeartbeatAgeSeconds 5 -NamePrefix 'unity-mcp-decoy' | Out-Null

            $launchScript = New-MaterializedLaunchScript
            # Note (test-critic fix): a parameterless placeholder script does NOT
            # throw on surplus named args in PowerShell (verified empirically),
            # so a "did not throw" assertion here would be vacuous either way -
            # removed. The RED-carrying assertion is the Test-Path below: the
            # placeholder script performs no adoption at all, so the directory
            # is never created.
            & $launchScript -AdoptOnly -CheckoutPath $checkout -GlobalStatusDir $globalDir 2>$null

            $statusDir = Join-Path $checkout '.unity-mcp'
            Test-Path $statusDir | Should Be $true

            $links = Get-ChildItem -Path $statusDir -Force
            $links.Count | Should Be 2
            foreach ($l in $links) {
                (Get-Item -Force $l.FullName).LinkType | Should Be 'SymbolicLink'
                # test-critic fix: the decoy fixture must actually be inspected -
                # a link that points at the decoy's files instead of the correct
                # instance's must fail this.
                (Get-Item -Force $l.FullName).Target | Should Not Match 'decoy'
            }
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }

    It 'a full (non -AdoptOnly) invocation also produces the links before the launch decision' {
        # Same symlink-capability gate as the test above, and for the same
        # reason: this is a real, unmocked & $launchScript invocation.
        if (-not $global:uma_symlinkCapable) {
            Write-Warning 'symlink creation unsupported in this sandbox (no Developer Mode / admin) - skipping this real-fixture test; see file header .NOTES.'
            return
        }
        # This fixture is deliberately a LIVE match (fresh heartbeat, open port):
        # per R3's decision table that is the "already connected" branch, which
        # never reaches an actual Unity launch - so this is safe to run as a full
        # (non -AdoptOnly) invocation without needing a real Unity editor/binary.
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $fake = Start-FakeUnityListener
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port -HeartbeatAgeSeconds 5 | Out-Null

            $launchScript = New-MaterializedLaunchScript
            # Note (test-critic fix): see the vacuous-"no throw" note in the
            # test above - removed here too. Expected RED: the here-string
            # doesn't exist yet, so the placeholder script does nothing at all -
            # no .unity-mcp dir, no links. A future implementation must run the
            # adoption pass before deciding to launch, for BOTH -AdoptOnly and a
            # full invocation (fixes critic F1 - one algorithm, both entry points).
            & $launchScript -CheckoutPath $checkout -GlobalStatusDir $globalDir 2>$null
            $statusDir = Join-Path $checkout '.unity-mcp'
            Test-Path $statusDir | Should Be $true
            (Get-ChildItem -Path $statusDir -Force | Measure-Object).Count | Should Be 2
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }

    It 'no match leaves the checkout untouched and exits 0' {
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        try {
            # globalDir has no fixtures at all.
            $launchScript = New-MaterializedLaunchScript
            $threw = $false
            try {
                & $launchScript -AdoptOnly -CheckoutPath $checkout -GlobalStatusDir $globalDir 2>$null
            } catch { $threw = $true }
            $threw | Should Be $false

            $statusDir = Join-Path $checkout '.unity-mcp'
            if (Test-Path $statusDir) {
                (Get-ChildItem -Path $statusDir -Force | Measure-Object).Count | Should Be 0
            }
        } finally { Remove-TempDir $checkout; Remove-TempDir $globalDir }
    }

    It 'a heartbeat older than 60s is not adopted' {
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $fake = Start-FakeUnityListener
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port -HeartbeatAgeSeconds 61 | Out-Null

            $launchScript = New-MaterializedLaunchScript
            $threw = $false
            try {
                & $launchScript -AdoptOnly -CheckoutPath $checkout -GlobalStatusDir $globalDir 2>$null
            } catch { $threw = $true }
            $threw | Should Be $false

            $statusDir = Join-Path $checkout '.unity-mcp'
            if (Test-Path $statusDir) {
                (Get-ChildItem -Path $statusDir -Force | Measure-Object).Count | Should Be 0
            }
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout; Remove-TempDir $globalDir
        }
    }

    It 'a closed port is not adopted' {
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        try {
            # Grab an ephemeral port, then release it immediately so nothing listens there.
            $probe = Start-FakeUnityListener
            $closedPort = $probe.Port
            Stop-FakeUnityListener $probe

            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $closedPort -HeartbeatAgeSeconds 5 | Out-Null

            $launchScript = New-MaterializedLaunchScript
            $threw = $false
            try {
                & $launchScript -AdoptOnly -CheckoutPath $checkout -GlobalStatusDir $globalDir 2>$null
            } catch { $threw = $true }
            $threw | Should Be $false

            $statusDir = Join-Path $checkout '.unity-mcp'
            if (Test-Path $statusDir) {
                (Get-ChildItem -Path $statusDir -Force | Measure-Object).Count | Should Be 0
            }
        } finally { Remove-TempDir $checkout; Remove-TempDir $globalDir }
    }

    It 'fails loudly with the Developer-Mode remedy when symlink creation is denied (Mock, not a substring search)' {
        # test-critic fix: the previous version of this test grepped the
        # source text for the phrase "Developer Mode", which a script whose
        # entire body is a no-op also "passes" trivially if the string
        # appears anywhere (e.g. a comment). Instead: dot-source the real
        # script, Mock the side-effecting New-AdoptionSymlink call to throw an
        # access-denied error (simulating Windows without Developer
        # Mode/admin, which this sandbox cannot reproduce for real - see file
        # header .NOTES), and assert Invoke-UnityMcpAdoption actually
        # re-throws / fails with the remedy text.
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $fake = Start-FakeUnityListener
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port -HeartbeatAgeSeconds 5 | Out-Null

            $launchScriptPath = New-MaterializedLaunchScript
            . $launchScriptPath

            Mock New-AdoptionSymlink { throw (New-Object System.UnauthorizedAccessException 'Access is denied.') }

            $errMessage = $null
            $failed = $false
            try {
                Invoke-UnityMcpAdoption -CheckoutPath $checkout -GlobalStatusDir $globalDir
            } catch {
                $errMessage = $_.Exception.Message
                $failed = $true
            }

            # Expected RED: Invoke-UnityMcpAdoption (and/or New-AdoptionSymlink,
            # which Mock must resolve via Get-Command to mock) is not defined
            # yet - the launchScript here-string does not exist - so this fails
            # for "not implemented", not for the access-denied path under test.
            $failed | Should Be $true
            $errMessage | Should Match '(?i)Developer Mode'
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }
}

# ---------------------------------------------------------------------------
# Review round 5 blocking fix - a relative -CheckoutPath must be canonicalized
# to an absolute path at the entry point, before it's used anywhere downstream
# (Find-AdoptionCandidate's project_path comparison, UNITY_MCP_STATUS_DIR).
# Chosen driving scenario: Find-AdoptionCandidate compares a value derived
# from -CheckoutPath (`$targetAssets`) against status-fixture JSON that always
# stores an ABSOLUTE project_path (real Unity behaviour). Without
# canonicalization, a relative -CheckoutPath makes `$targetAssets` relative,
# so it can never equal the fixture's absolute path and adoption silently
# fails to match.
#
# This must still go through the real ENTRY POINT (`& $launchScript`, not
# dot-sourcing) since the fix lives there, not inside any individual
# function - but a real entry-point invocation that actually matches a
# candidate calls the real (unmocked) New-AdoptionSymlink, which needs
# Developer Mode/admin privilege this sandbox lacks (see file header
# .NOTES) and which Pester's `Mock` cannot intercept here anyway: `&
# $launchScript` re-defines all of the script's functions in a fresh child
# scope, so a `Mock` registered in the CALLER's scope is shadowed by the
# script's own same-scope definition rather than being called. Instead,
# New-MaterializedLaunchScriptWithSymlinkStub below textually inserts a
# replacement `New-AdoptionSymlink` definition into the materialized copy,
# immediately before the entry-point block - since PowerShell registers a
# top-level function the moment execution reaches its `function` statement,
# this later definition simply overwrites the real one for every call made
# once the entry point runs, with no privilege needed and no bypass of the
# canonicalization fix under test.
# ---------------------------------------------------------------------------
function New-MaterializedLaunchScriptWithSymlinkStub {
    param([Parameter(Mandatory)][string]$RecordPath)
    $src = $global:uma_launchScriptSrc
    if ([string]::IsNullOrEmpty($src)) {
        $src = '# launchScript here-string not found in prepare-unity-worktree.ps1 (ticket #47 not yet implemented)'
    }
    $marker = '# Entry point'
    $idx = $src.IndexOf($marker)
    if ($idx -lt 0) {
        throw "New-MaterializedLaunchScriptWithSymlinkStub: could not find entry-point marker '$marker' in launchScript source - has it been renamed?"
    }
    $stub = @"
function New-AdoptionSymlink {
    param([Parameter(Mandatory)][string]`$LinkPath, [Parameter(Mandatory)][string]`$Target)
    Add-Content -Path '$RecordPath' -Value `$LinkPath
}

"@
    $patched = $src.Substring(0, $idx) + $stub + $src.Substring($idx)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("uma-launch-stub-" + [System.IO.Path]::GetRandomFileName() + '.ps1')
    Write-Utf8NoBom -Path $tmp -Content $patched
    return $tmp
}

Describe 'unity-mcp-launch.ps1 -AdoptOnly - canonicalizes a relative -CheckoutPath before use (ticket #47 / review round 5 blocking fix)' {

    It 'still adopts a live Hub-started editor when -CheckoutPath is passed as a relative path' {
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $recordPath = Join-Path ([System.IO.Path]::GetTempPath()) ("uma-symlink-calls-" + [guid]::NewGuid() + '.txt')
        $fake = $null
        $originalLocation = Get-Location
        try {
            $fake = Start-FakeUnityListener
            # The fixture's project_path is the checkout's ABSOLUTE Assets path -
            # exactly what a real Unity instance would report.
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port -HeartbeatAgeSeconds 5 | Out-Null

            $launchScript = New-MaterializedLaunchScriptWithSymlinkStub -RecordPath $recordPath
            # Invoke with a RELATIVE -CheckoutPath: cd into the checkout's parent
            # and pass only its leaf name. Pre-fix, Find-AdoptionCandidate would
            # compare a relative $targetAssets against the fixture's absolute
            # project_path and never match - New-AdoptionSymlink (the stub)
            # would never be called at all, and $recordPath would stay empty.
            Set-Location (Split-Path -Parent $checkout)
            $relativeCheckout = Split-Path -Leaf $checkout
            & $launchScript -AdoptOnly -CheckoutPath $relativeCheckout -GlobalStatusDir $globalDir 2>$null

            Test-Path $recordPath | Should Be $true
            $recordedLinks = @(Get-Content -Path $recordPath)
            $recordedLinks.Count | Should Be 2
            # Each recorded LinkPath must be an absolute path under the
            # checkout's OWN .unity-mcp dir - proves not just that adoption
            # matched, but that it matched the correct (absolute-resolved)
            # checkout, not some unrelated relative interpretation.
            $expectedStatusDir = Join-Path $checkout '.unity-mcp'
            foreach ($link in $recordedLinks) {
                [System.IO.Path]::IsPathRooted($link) | Should Be $true
                $link | Should Match ([regex]::Escape($expectedStatusDir))
            }
        } finally {
            Set-Location $originalLocation
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
            Remove-Item -Force -ErrorAction SilentlyContinue $recordPath
        }
    }
}

# ---------------------------------------------------------------------------
# Review round 1 blocking fix - Invoke-UnityMcpAdoption must not treat ANY
# existing real status file as a reason to skip scanning; only a LIVE one.
# A stale real file (crashed prior instance) must not permanently block
# adoption of a later Hub-started editor for the same checkout. The stale
# file itself is left in place (not deleted) - only symlink entries are ever
# removed by this preamble, consistent with the pre-existing "stale-but-
# present" invariant asserted in tests\prepare-unity-worktree.Tests.ps1's R3
# Describe block.
# ---------------------------------------------------------------------------
Describe 'Invoke-UnityMcpAdoption - a stale real status file does not block adoption (ticket #47 / review round 1 blocking fix)' {

    It 'ignores a stale existing real status file (leaving it in place) and still adopts a live Hub-started candidate' {
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $statusDir = Join-Path $checkout '.unity-mcp'
            New-Item -ItemType Directory -Force -Path $statusDir | Out-Null

            # A stale REAL (non-symlink) status file already sitting in the
            # checkout's own .unity-mcp - simulates a crashed prior agent-started
            # instance. Heartbeat is 120s old, well past the 60s threshold.
            New-StatusFixture -GlobalStatusDir $statusDir -ProjectPath (Join-Path $checkout 'Assets') -Port 9999 -HeartbeatAgeSeconds 120 | Out-Null
            $staleStatusFile = Join-Path $statusDir 'unity-mcp-status-9999.json'
            Test-Path $staleStatusFile | Should Be $true

            # A live Hub-started editor for this same checkout, discoverable in
            # the global status dir.
            $fake = Start-FakeUnityListener
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port -HeartbeatAgeSeconds 5 | Out-Null

            $launchScriptPath = New-MaterializedLaunchScript
            . $launchScriptPath

            # Mock the side-effecting symlink call so this test does not depend
            # on Developer Mode/admin privilege (same rationale as the "fails
            # loudly" Mock test above) - the point under test is whether
            # adoption PROCEEDS past the stale real file, not whether a real
            # symlink gets created. Count calls via an explicit counter rather
            # than Assert-MockCalled: Pester 3.4's mock call history for a
            # given command name is not reliably reset by re-declaring `Mock`
            # in a later It block of the same Describe (observed empirically:
            # a second It's Assert-MockCalled -Times 0 saw the first It's 2
            # calls), so a fresh, explicitly-reset counter is the only
            # reliable count in this Pester version.
            $global:uma_symlinkCallCount = 0
            Mock New-AdoptionSymlink { $global:uma_symlinkCallCount++ }

            $threw = $false
            try {
                Invoke-UnityMcpAdoption -CheckoutPath $checkout -GlobalStatusDir $globalDir
            } catch { $threw = $true }

            # Expected RED (pre-fix): Invoke-UnityMcpAdoption returns as soon as
            # it sees ANY real status file, regardless of liveness - so
            # New-AdoptionSymlink is never called for the live Hub candidate.
            # The stale file itself is left untouched either way - only
            # symlink entries are ever deleted by this preamble (consistent
            # with tests\prepare-unity-worktree.Tests.ps1's R3 "stale-but-
            # present" test, which asserts a stale REAL file survives).
            $threw | Should Be $false
            Test-Path $staleStatusFile | Should Be $true
            $global:uma_symlinkCallCount | Should Be 2
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }

    It 'still exits without scanning when the existing real status file IS live' {
        # Companion case: a genuinely live real status file (this session's own
        # prior instance, still running) must still short-circuit adoption -
        # the fix must not regress the original "already adopted" behaviour.
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $statusDir = Join-Path $checkout '.unity-mcp'
            New-Item -ItemType Directory -Force -Path $statusDir | Out-Null

            $fake = Start-FakeUnityListener
            New-StatusFixture -GlobalStatusDir $statusDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port -HeartbeatAgeSeconds 5 | Out-Null
            $liveStatusFile = Join-Path $statusDir "unity-mcp-status-$($fake.Port).json"

            $launchScriptPath = New-MaterializedLaunchScript
            . $launchScriptPath

            # See the counter-vs-Assert-MockCalled note in the sibling It above.
            $global:uma_symlinkCallCount = 0
            Mock New-AdoptionSymlink { $global:uma_symlinkCallCount++ }

            $threw = $false
            try {
                Invoke-UnityMcpAdoption -CheckoutPath $checkout -GlobalStatusDir $globalDir
            } catch { $threw = $true }

            $threw | Should Be $false
            Test-Path $liveStatusFile | Should Be $true
            $global:uma_symlinkCallCount | Should Be 0
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }
}

# ---------------------------------------------------------------------------
# Review round 3 blocking fix - a stale real status file whose leaf name
# happens to collide with the adoption candidate's target filename (ports are
# reused after a crash, filenames are port-derived) must not permanently wedge
# adoption. Invoke-UnityMcpAdoption already proves the file is stale before
# reaching New-AdoptionSymlink; it must remove exactly that colliding stale
# file, not every stale file, or the round 1 "stale file survives" invariant
# (this file's preceding Describe) would regress.
# ---------------------------------------------------------------------------
# Each scenario below lives in its OWN Describe block, even though all three
# exercise the same collision-scoped removal fix, because of an empirically
# observed Pester 3.4 limitation in this sandbox (consistent with this file's
# existing "mock call history is not reliably reset" notes elsewhere): a
# SECOND `Mock New-AdoptionSymlink` declared in a LATER It of the SAME
# Describe silently fails to re-hook the function - the real (unmocked)
# New-AdoptionSymlink runs instead, hitting the real New-Item -ItemType
# SymbolicLink call and failing on this sandbox's missing Developer
# Mode/admin privilege. Verified empirically while writing these tests
# (moving a second/third It's Mock into its own Describe made it take effect
# again). One Describe per Mocked scenario sidesteps it entirely.
Describe 'Invoke-UnityMcpAdoption - collision-scoped stale-file removal (ticket #47 / review round 3 blocking fix)' {

    It 'removes a stale real status file that collides with the candidates target filename, then adopts successfully' {
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $statusDir = Join-Path $checkout '.unity-mcp'
            New-Item -ItemType Directory -Force -Path $statusDir | Out-Null

            $fake = Start-FakeUnityListener

            # Live Hub candidate for this checkout, discoverable in the global dir.
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port -HeartbeatAgeSeconds 5 | Out-Null

            # A stale REAL status file already sitting in the checkout's own
            # .unity-mcp, whose leaf name COLLIDES with the candidate's status
            # filename (same port - plausible after a crash + port reuse).
            # Heartbeat is 120s old, well past the 60s threshold - proven stale
            # by Invoke-UnityMcpAdoption's own existingReal/liveReal check.
            New-StatusFixture -GlobalStatusDir $statusDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port -HeartbeatAgeSeconds 120 | Out-Null
            $collidingStatusFile = Join-Path $statusDir "unity-mcp-status-$($fake.Port).json"
            Test-Path $collidingStatusFile | Should Be $true

            $launchScriptPath = New-MaterializedLaunchScript
            . $launchScriptPath

            $global:uma_symlinkCallCount = 0
            # A faithful replica of New-AdoptionSymlink's own refusal guard
            # (the real function is unchanged by this test) - throws iff a
            # real, non-link file still sits at LinkPath. Using a replica
            # (rather than a real New-Item -ItemType SymbolicLink call) lets
            # this test run without Developer Mode/admin privilege while still
            # reproducing the exact pre-fix wedge: Invoke-UnityMcpAdoption
            # calling this for a colliding path it never cleaned up first.
            Mock New-AdoptionSymlink {
                param($LinkPath, $Target)
                $existing = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
                if ($existing -and -not (Test-EntryIsLink -Entry $existing)) {
                    throw "Refusing to adopt: a real (non-symlink) file already exists at '$LinkPath'. Not overwriting it."
                }
                $global:uma_symlinkCallCount++
            }

            $threw = $false
            try {
                Invoke-UnityMcpAdoption -CheckoutPath $checkout -GlobalStatusDir $globalDir
            } catch { $threw = $true }

            # Expected RED (pre-fix): Invoke-UnityMcpAdoption never removes the
            # colliding stale file before calling New-AdoptionSymlink, so the
            # (faithful) mock throws "Refusing to adopt...", which propagates
            # out of Invoke-UnityMcpAdoption uncaught for this cause -
            # wedging adoption entirely.
            $threw | Should Be $false
            $global:uma_symlinkCallCount | Should Be 2
            Test-Path $collidingStatusFile | Should Be $false
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }
}

Describe 'Invoke-UnityMcpAdoption - collision-scoped stale-file removal, port-file symmetry (ticket #47 / review round 4 nit fix)' {

    It 'removes a stale real PORT file that collides with the candidates target filename, then adopts successfully' {
        # Symmetric counterpart to the status-file collision Describe above:
        # the removal foreach loop walks @($statusLink, $portLink) and
        # $existingReal is the union of $existingRealStatus and
        # $existingRealPort (scripts\prepare-unity-worktree.ps1), so the
        # port-file branch deserves its own driving test rather than relying
        # on the status-file case to stand in for both. Only a colliding
        # PORT file is planted here (no colliding status file), isolating the
        # $portLink iteration of the loop.
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $statusDir = Join-Path $checkout '.unity-mcp'
            New-Item -ItemType Directory -Force -Path $statusDir | Out-Null

            $fake = Start-FakeUnityListener

            # Live Hub candidate for this checkout, discoverable in the global dir.
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port -HeartbeatAgeSeconds 5 | Out-Null

            # A stale REAL port file (deliberately no colliding status file)
            # already sitting in the checkout's own .unity-mcp, whose leaf
            # name COLLIDES with the candidate's port filename (same port -
            # plausible after a crash + port reuse). Port files carry no
            # last_heartbeat field, so Test-StatusFileLive always reads them
            # as "not live" - proven stale unconditionally, per the header
            # comment above $existingRealStatus/$existingRealPort.
            $collidingPortFile = Join-Path $statusDir "unity-mcp-port-$($fake.Port).json"
            (@{ unity_port = $fake.Port } | ConvertTo-Json) | Set-Content -Path $collidingPortFile -Encoding UTF8
            Test-Path $collidingPortFile | Should Be $true

            $launchScriptPath = New-MaterializedLaunchScript
            . $launchScriptPath

            $global:uma_symlinkCallCount = 0
            # Same faithful replica of New-AdoptionSymlink's refusal guard as
            # the status-file Describe above.
            Mock New-AdoptionSymlink {
                param($LinkPath, $Target)
                $existing = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
                if ($existing -and -not (Test-EntryIsLink -Entry $existing)) {
                    throw "Refusing to adopt: a real (non-symlink) file already exists at '$LinkPath'. Not overwriting it."
                }
                $global:uma_symlinkCallCount++
            }

            $threw = $false
            try {
                Invoke-UnityMcpAdoption -CheckoutPath $checkout -GlobalStatusDir $globalDir
            } catch { $threw = $true }

            # If the removal loop's $portLink branch were ever dropped (e.g. a
            # future edit narrowing @($statusLink, $portLink) back down to
            # just $statusLink), this would regress to the same wedge the
            # round 3 fix addressed: the (faithful) mock throws "Refusing to
            # adopt...", which propagates out of Invoke-UnityMcpAdoption
            # uncaught.
            $threw | Should Be $false
            $global:uma_symlinkCallCount | Should Be 2
            Test-Path $collidingPortFile | Should Be $false
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }
}

Describe 'Invoke-UnityMcpAdoption - remedy text on a non-permission New-AdoptionSymlink failure (ticket #47 / review round 3 nit fix)' {

    It 'a genuine "real file already exists" failure surfaces as-is, without the Developer-Mode remedy text (round 3 nit fix)' {
        # A real (non-link) file New-AdoptionSymlink refuses to overwrite for
        # a reason OTHER than the collision case fixed above - e.g. a real
        # file created at the link path in the race window between
        # Invoke-UnityMcpAdoption's existingReal scan (which covers both
        # unity-mcp-status-*.json and unity-mcp-port-*.json) and the
        # New-AdoptionSymlink call itself. Enabling Developer Mode/
        # Administrator does nothing to fix this cause, so the remedy text
        # must not be attached to it.
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $fake = Start-FakeUnityListener
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port -HeartbeatAgeSeconds 5 | Out-Null

            $launchScriptPath = New-MaterializedLaunchScript
            . $launchScriptPath

            Mock New-AdoptionSymlink { throw "Refusing to adopt: a real (non-symlink) file already exists at 'somewhere.json'. Not overwriting it." }

            $errMessage = $null
            $failed = $false
            try {
                Invoke-UnityMcpAdoption -CheckoutPath $checkout -GlobalStatusDir $globalDir
            } catch {
                $errMessage = $_.Exception.Message
                $failed = $true
            }

            # Expected RED (pre-fix): the catch block attached the
            # Developer-Mode/Administrator remedy text unconditionally to
            # every New-AdoptionSymlink failure, including this one.
            $failed | Should Be $true
            $errMessage | Should Match 'Refusing to adopt'
            $errMessage | Should Not Match '(?i)Developer Mode'
            $errMessage | Should Not Match '(?i)Administrator privilege'
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }
}

Describe 'Invoke-UnityMcpAdoption - collision-scoped removal does not regress the non-collision case (ticket #47 / review round 3 regression guard)' {

    It 'a stale real status file that does NOT collide with anything still survives untouched (regression guard)' {
        # Restates the round 1 Describe's non-collision scenario explicitly as
        # this round's regression guard, per the review's own wording: a
        # stale file whose port (9999) never collides with the candidate's
        # ($fake.Port, ephemeral) must never trigger the narrower,
        # collision-scoped removal added above.
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $statusDir = Join-Path $checkout '.unity-mcp'
            New-Item -ItemType Directory -Force -Path $statusDir | Out-Null

            New-StatusFixture -GlobalStatusDir $statusDir -ProjectPath (Join-Path $checkout 'Assets') -Port 9999 -HeartbeatAgeSeconds 120 | Out-Null
            $nonCollidingStatusFile = Join-Path $statusDir 'unity-mcp-status-9999.json'
            Test-Path $nonCollidingStatusFile | Should Be $true

            $fake = Start-FakeUnityListener
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port -HeartbeatAgeSeconds 5 | Out-Null

            $launchScriptPath = New-MaterializedLaunchScript
            . $launchScriptPath

            $global:uma_symlinkCallCount = 0
            Mock New-AdoptionSymlink { $global:uma_symlinkCallCount++ }

            $threw = $false
            try {
                Invoke-UnityMcpAdoption -CheckoutPath $checkout -GlobalStatusDir $globalDir
            } catch { $threw = $true }

            $threw | Should Be $false
            Test-Path $nonCollidingStatusFile | Should Be $true
            $global:uma_symlinkCallCount | Should Be 2
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }
}

# ---------------------------------------------------------------------------
# R1 (test-critic fix) - the pure decision function, called directly and
# dot-sourced (not through a full script invocation), so a wrong-instance
# selection or a threshold that isn't actually enforced fails these tests
# regardless of symlink privilege.
# ---------------------------------------------------------------------------
Describe 'Find-AdoptionCandidate - pure decision function, no side effects (ticket #47 / R1, test-critic fix)' {

    It 'selects the candidate whose project_path resolves to <checkout>/Assets, excluding a decoy for another project' {
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $fake = Start-FakeUnityListener
            $correct = New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port -HeartbeatAgeSeconds 5
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath 'C:\some\other\project\Assets' -Port 12345 -HeartbeatAgeSeconds 5 -NamePrefix 'unity-mcp-decoy' | Out-Null

            $launchScriptPath = New-MaterializedLaunchScript
            . $launchScriptPath

            $result = $null
            $threw = $false
            try {
                $result = Find-AdoptionCandidate -CheckoutPath $checkout -GlobalStatusDir $globalDir -HeartbeatMaxAgeSeconds 60 -PortProbeTimeoutMs 500
            } catch { $threw = $true }

            # Expected RED: Find-AdoptionCandidate is not defined yet (no
            # $launchScript here-string) -> CommandNotFoundException.
            $threw | Should Be $false
            $result | Should Not BeNullOrEmpty
            $result.StatusFile | Should Be $correct.StatusFile
            $result.PortFile   | Should Be $correct.PortFile
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout; Remove-TempDir $globalDir
        }
    }

    It 'a heartbeat older than 60s is not selected (returns $null)' {
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $fake = Start-FakeUnityListener
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port -HeartbeatAgeSeconds 61 | Out-Null

            $launchScriptPath = New-MaterializedLaunchScript
            . $launchScriptPath

            $result = 'unset'
            $threw = $false
            try {
                $result = Find-AdoptionCandidate -CheckoutPath $checkout -GlobalStatusDir $globalDir -HeartbeatMaxAgeSeconds 60 -PortProbeTimeoutMs 500
            } catch { $threw = $true }

            $threw | Should Be $false
            $result | Should Be $null
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout; Remove-TempDir $globalDir
        }
    }

    It 'a closed port is not selected (returns $null)' {
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        try {
            $probe = Start-FakeUnityListener
            $closedPort = $probe.Port
            Stop-FakeUnityListener $probe

            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $closedPort -HeartbeatAgeSeconds 5 | Out-Null

            $launchScriptPath = New-MaterializedLaunchScript
            . $launchScriptPath

            $result = 'unset'
            $threw = $false
            try {
                $result = Find-AdoptionCandidate -CheckoutPath $checkout -GlobalStatusDir $globalDir -HeartbeatMaxAgeSeconds 60 -PortProbeTimeoutMs 500
            } catch { $threw = $true }

            $threw | Should Be $false
            $result | Should Be $null
        } finally { Remove-TempDir $checkout; Remove-TempDir $globalDir }
    }

    It 'no candidates in the global dir returns $null' {
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        try {
            $launchScriptPath = New-MaterializedLaunchScript
            . $launchScriptPath

            $result = 'unset'
            $threw = $false
            try {
                $result = Find-AdoptionCandidate -CheckoutPath $checkout -GlobalStatusDir $globalDir -HeartbeatMaxAgeSeconds 60 -PortProbeTimeoutMs 500
            } catch { $threw = $true }

            $threw | Should Be $false
            $result | Should Be $null
        } finally { Remove-TempDir $checkout; Remove-TempDir $globalDir }
    }

    It 'a malformed non-numeric port field is skipped without aborting the scan for other valid entries (review round 2 blocking fix)' {
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $fake = Start-FakeUnityListener
            $correct = New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port -HeartbeatAgeSeconds 5

            # A malformed status file for the SAME project - matches
            # project_path and a fresh heartbeat, but carries a non-numeric
            # port (e.g. a partially written / corrupted status file). Named
            # so it sorts before the valid fixture above in most filesystem
            # enumerations, but the fix must survive either order.
            $badObj = [pscustomobject]@{
                project_path   = (Join-Path $checkout 'Assets')
                unity_port     = 'not-a-number'
                last_heartbeat = (Get-Date).ToUniversalTime().AddSeconds(-5).ToString('o')
            }
            $badFile = Join-Path $globalDir 'unity-mcp-status-0-bad.json'
            ($badObj | ConvertTo-Json) | Set-Content -Path $badFile -Encoding UTF8

            $launchScriptPath = New-MaterializedLaunchScript
            . $launchScriptPath

            $result = $null
            $threw = $false
            try {
                $result = Find-AdoptionCandidate -CheckoutPath $checkout -GlobalStatusDir $globalDir -HeartbeatMaxAgeSeconds 60 -PortProbeTimeoutMs 500
            } catch { $threw = $true }

            # Expected RED (pre-fix): the unguarded [int]$data.port cast
            # throws a terminating exception for the malformed entry (the
            # generated launch script runs under $ErrorActionPreference =
            # 'Stop'), propagating out of the foreach loop instead of being
            # treated as "not a match" - Find-AdoptionCandidate never
            # reaches the valid candidate.
            $threw | Should Be $false
            $result | Should Not BeNullOrEmpty
            $result.StatusFile | Should Be $correct.StatusFile
            $result.PortFile   | Should Be $correct.PortFile
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout; Remove-TempDir $globalDir
        }
    }
}

# ---------------------------------------------------------------------------
# Review round 2 blocking fix - New-AdoptionSymlink must never delete/overwrite
# a real (non-link) file already occupying LinkPath. Prior to this fix, the
# guard was a bare Test-Path + unconditional Remove-Item, unlike
# Remove-StaleAdoptionLinks (which correctly gates on Test-EntryIsLink first).
# Since Invoke-UnityMcpAdoption now deliberately proceeds past a stale real
# status file (round 1 fix) instead of returning early, a same-named Hub
# candidate's adoption link creation could otherwise silently delete that real
# local file.
# ---------------------------------------------------------------------------
Describe 'New-AdoptionSymlink - refuses to overwrite a real (non-link) file (ticket #47 / review round 2 blocking fix)' {

    It 'never deletes a real (non-link) file at LinkPath - throws a clear error instead of clobbering it' {
        $tmp = New-TempDir
        try {
            $launchScriptPath = New-MaterializedLaunchScript
            . $launchScriptPath

            $linkPath = Join-Path $tmp 'unity-mcp-status-real.json'
            Set-Content -Path $linkPath -Value '{"real":true}' -Encoding UTF8 -NoNewline

            $targetPath = Join-Path $tmp 'somewhere-else-status.json'
            Set-Content -Path $targetPath -Value '{"target":true}' -Encoding UTF8 -NoNewline

            $errMessage = $null
            try {
                New-AdoptionSymlink -LinkPath $linkPath -Target $targetPath
            } catch { $errMessage = $_.Exception.Message }

            # Expected RED (pre-fix): New-AdoptionSymlink's guard is a bare
            # Test-Path, with no check that the existing entry is actually a
            # symlink/reparse-point - it unconditionally Remove-Item's
            # whatever sits at LinkPath, deleting the real file here
            # regardless of whether the subsequent
            # New-Item -ItemType SymbolicLink itself then succeeds or (in a
            # sandbox lacking Developer Mode/admin) fails.
            Test-Path -LiteralPath $linkPath | Should Be $true
            (Get-Content -LiteralPath $linkPath -Raw) | Should Match 'real'
            $errMessage | Should Not BeNullOrEmpty
            $errMessage | Should Not Match '(?i)Administrator privilege required'
        } finally { Remove-TempDir $tmp }
    }
}

# ---------------------------------------------------------------------------
# R2 — a stale or dangling adopted link is removed before any launch
# (Day-1/Day-2).
# ---------------------------------------------------------------------------
Describe 'unity-mcp-launch.ps1 -AdoptOnly - removes a stale or dangling adopted link before launch (ticket #47 / R2)' {

    It 'structural: $puw_launchScript unconditionally cleans up symlink entries (LinkType/ReparsePoint) before adopting' {
        $text = [string]$global:uma_launchScriptSrc
        ($text -match 'LinkType' -or $text -match 'ReparsePoint') | Should Be $true
    }

    It 'a dangling symlink (target deleted) is removed without throwing; a real file in the same dir survives' {
        if (-not $global:uma_symlinkCapable) {
            Write-Warning 'symlink creation unsupported in this sandbox (no Developer Mode / admin) - skipping this real-fixture test; see file header .NOTES. Coverage carried by the structural test above plus the behavioural replica below.'
            return
        }
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        try {
            $statusDir = Join-Path $checkout '.unity-mcp'
            New-Item -ItemType Directory -Force -Path $statusDir | Out-Null

            $target = Join-Path $globalDir 'unity-mcp-status-9999.json'
            Set-Content -Path $target -Value '{}' -Encoding UTF8
            $linkPath = Join-Path $statusDir 'unity-mcp-status-9999.json'
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $target -ErrorAction Stop | Out-Null
            Remove-Item -Path $target -Force

            $realFile = Join-Path $statusDir 'unity-mcp-status-real.json'
            Set-Content -Path $realFile -Value '{}' -Encoding UTF8

            # test-critic fix: call the REAL cleanup function directly (dot-sourced),
            # not the full script, and verify via Get-ChildItem (directory-entry
            # enumeration) rather than Test-Path - Test-Path on a dangling symlink
            # resolves the (missing) target and returns $false regardless of
            # whether the link's directory entry was actually removed, so it
            # cannot distinguish "cleaned up" from "never touched".
            $launchScriptPath = New-MaterializedLaunchScript
            . $launchScriptPath

            $threw = $false
            try {
                Remove-StaleAdoptionLinks -StatusDir $statusDir
            } catch { $threw = $true }

            # Expected RED: Remove-StaleAdoptionLinks is not defined yet (no
            # $launchScript here-string) -> CommandNotFoundException.
            $threw | Should Be $false
            $remainingNames = @(Get-ChildItem -Path $statusDir -Force | Select-Object -ExpandProperty Name)
            $remainingNames | Should Not Contain 'unity-mcp-status-9999.json'
            $remainingNames | Should Contain 'unity-mcp-status-real.json'
        } finally { Remove-TempDir $checkout; Remove-TempDir $globalDir }
    }

    It 'real (non-link) files in .unity-mcp survive Remove-StaleAdoptionLinks untouched' {
        # test-critic fix: replaces the self-referential "Invoke-CleanupReplica"
        # test, which asserted a locally-defined function against itself and
        # could never fail regardless of what the real script does. This test
        # calls the REAL cleanup function. Environment limitation: this sandbox
        # cannot create a real dangling symlink (see file header .NOTES), so
        # the "does a dangling link actually get removed" half of R2 is proven
        # by the symlink-capable-gated test above when privilege is available;
        # this test proves the other, privilege-free half of the same
        # contract - real files are never deleted by the cleanup pass.
        $checkout = New-TempDir
        try {
            $statusDir = Join-Path $checkout '.unity-mcp'
            New-Item -ItemType Directory -Force -Path $statusDir | Out-Null
            $realFile1 = Join-Path $statusDir 'unity-mcp-status-real.json'
            $realFile2 = Join-Path $statusDir 'unity-mcp-port-real.json'
            Set-Content -Path $realFile1 -Value '{}' -Encoding UTF8
            Set-Content -Path $realFile2 -Value '{}' -Encoding UTF8

            $launchScriptPath = New-MaterializedLaunchScript
            . $launchScriptPath

            $threw = $false
            try {
                Remove-StaleAdoptionLinks -StatusDir $statusDir
            } catch { $threw = $true }

            # Expected RED: Remove-StaleAdoptionLinks is not defined yet ->
            # CommandNotFoundException.
            $threw | Should Be $false
            Test-Path $realFile1 | Should Be $true
            Test-Path $realFile2 | Should Be $true
        } finally { Remove-TempDir $checkout }
    }
}

# ---------------------------------------------------------------------------
# R9 — the SessionStart hook is wired, resolvable, and harmless on
# non-Unity projects.
# ---------------------------------------------------------------------------
Describe 'hooks/hooks.json + hooks/session-start-adopt.ps1 - wired, resolvable, harmless (ticket #47 / R9)' {

    $hooksJsonPath = Join-Path $global:uma_repoRoot 'hooks\hooks.json'
    $shimPath      = Join-Path $global:uma_repoRoot 'hooks\session-start-adopt.ps1'

    It 'hooks/hooks.json exists and parses as JSON declaring a SessionStart hook' {
        Test-Path $hooksJsonPath | Should Be $true
        $json = Get-Content -LiteralPath $hooksJsonPath -Raw | ConvertFrom-Json
        $json.hooks.PSObject.Properties.Name -contains 'SessionStart' | Should Be $true
    }

    It 'the SessionStart command resolves its ${CLAUDE_PLUGIN_ROOT}-relative path to a real shim on disk' {
        # test-critic fix: the previous version built $shimPath independently
        # (a literal hardcoded path) and never actually used the command
        # string to find it - a renamed/relocated shim would still pass. This
        # parses hooks.json's own command text, extracts the path portion
        # after ${CLAUDE_PLUGIN_ROOT}, resolves it against the repo root, and
        # Test-Paths THAT resolved path.
        Test-Path $hooksJsonPath | Should Be $true
        $commandText = (Get-Content -LiteralPath $hooksJsonPath -Raw | ConvertFrom-Json).hooks.SessionStart | Out-String
        $commandText | Should Match 'session-start-adopt\.ps1'
        $commandText | Should Match '\$\{CLAUDE_PLUGIN_ROOT\}'

        $null = $commandText -match '\$\{CLAUDE_PLUGIN_ROOT\}([^\s"'']+)'
        $relPath = $Matches[1]
        $relPath | Should Not BeNullOrEmpty
        $resolvedPath = Join-Path $global:uma_repoRoot ($relPath.TrimStart('/', '\') -replace '/', '\')
        Test-Path $resolvedPath | Should Be $true
    }

    It 'the SessionStart command uses pwsh -NoProfile -File and names a bounded timeout' {
        Test-Path $hooksJsonPath | Should Be $true
        $commandText = (Get-Content -LiteralPath $hooksJsonPath -Raw | ConvertFrom-Json).hooks.SessionStart | Out-String
        $commandText | Should Match 'pwsh'
        $commandText | Should Match '-NoProfile'
        $commandText | Should Match '-File'
        $commandText | Should Match '(?i)timeout'
    }

    It 'shim exits 0 without output on a project with no .seretos/unity-mcp-launch.ps1' {
        Test-Path $shimPath | Should Be $true
        $tmpProj = New-TempDir
        try {
            $prevProjDir = $env:CLAUDE_PROJECT_DIR
            $env:CLAUDE_PROJECT_DIR = $tmpProj
            $out = & pwsh -NoProfile -File $shimPath *>&1 | Out-String
            $LASTEXITCODE | Should Be 0
            $out.Trim() | Should Be ''
        } finally {
            if ($null -eq $prevProjDir) { Remove-Item Env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDE_PROJECT_DIR = $prevProjDir }
            Remove-TempDir $tmpProj
        }
    }

    It 'shim delegates with -AdoptOnly when .seretos/unity-mcp-launch.ps1 exists' {
        Test-Path $shimPath | Should Be $true
        $tmpProj = New-TempDir
        try {
            $seretosDir = Join-Path $tmpProj '.seretos'
            New-Item -ItemType Directory -Force -Path $seretosDir | Out-Null
            $stubPath    = Join-Path $seretosDir 'unity-mcp-launch.ps1'
            $recordPath  = Join-Path $tmpProj 'recorded-args.txt'
            $stubContent = "param([switch]`$AdoptOnly,[string]`$CheckoutPath)`n`"AdoptOnly=`$AdoptOnly CheckoutPath=`$CheckoutPath`" | Set-Content -Path '$recordPath'"
            Write-Utf8NoBom -Path $stubPath -Content $stubContent

            $prevProjDir = $env:CLAUDE_PROJECT_DIR
            $env:CLAUDE_PROJECT_DIR = $tmpProj
            & pwsh -NoProfile -File $shimPath *>&1 | Out-Null

            Test-Path $recordPath | Should Be $true
            $recorded = Get-Content -LiteralPath $recordPath -Raw
            $recorded | Should Match 'AdoptOnly=True'
            # test-critic fix: the stub recorded -CheckoutPath but nothing ever
            # checked it - assert it matches the $env:CLAUDE_PROJECT_DIR value
            # the shim was actually invoked with.
            $recorded | Should Match ([regex]::Escape("CheckoutPath=$tmpProj"))
        } finally {
            if ($null -eq $prevProjDir) { Remove-Item Env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDE_PROJECT_DIR = $prevProjDir }
            Remove-TempDir $tmpProj
        }
    }
}
