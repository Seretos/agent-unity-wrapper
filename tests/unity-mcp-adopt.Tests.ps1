#Requires -Version 5.1
<#
.SYNOPSIS
  Pester 3.x driving tests for ticket #52: Unity Hub adoption rebuilt as a
  real, dot-sourceable/invokable script (scripts/unity-mcp-adopt.ps1) - not a
  here-string generated into .seretos/. Status-file-only copy adoption
  (no port file, no symlink, no Developer Mode/Admin), TCP-probe-only
  liveness, normalized path matching, and the hooks.json PreToolUse
  registration that replaces SessionStart.

  Run with:  Invoke-Pester .\tests\unity-mcp-adopt.Tests.ps1 -Verbose

.NOTES
  Phase=tests (RED). scripts/unity-mcp-adopt.ps1 does not exist yet, so every
  test that dot-sources or invokes it fails for that reason - this IS the
  expected RED named by the ticket #52 plan (.adev/52-1/plan.md) for
  R1/R3/R4/R5 ("script does not exist -> dot-source fails" / "functions
  absent" / "absent implementation"), not an accidental typo or environment
  break: the whole point of this ticket is that the script does not exist
  yet. R6 (hooks.json) and R7/R8 (scripts/prepare-unity-worktree.ps1, see
  tests\prepare-unity-worktree.Tests.ps1) RED against the CURRENT production
  files instead, for the reasons noted at each Describe below.

  Assumed contract (this developer's contract for phase=implement, following
  the plan's Approach section and the naming precedent set by ticket #47's
  equivalent tests): Find-AdoptionCandidate returns $null or a hashtable/
  object with at least a `.StatusFile` property (no `.PortFile` - R4 deletes
  the port-file concept entirely). Diagnostics are emitted via Write-Output
  (plan: "Diagnostics go to stdout via Write-Output"), so they are captured
  here by piping a direct function call's output, not by reading a
  Write-Host/Write-Warning stream.

  Two plan-critique resolutions recorded here per the developer's brief:
    1. R2's edge case ("a quoted project_path is rejected as unreadable") vs.
       Get-ComparablePath's normalization rule (which trims surrounding
       quotes before comparing): resolved in favor of the normalization rule
       as primary intent - a validly quoted, otherwise-matching project_path
       DOES adopt (tested below as its own case); "rejected as unreadable" is
       tested only for a genuinely empty/whitespace project_path.
    2. R9's fourth rejection token ("not adopted (another live candidate
       already adopted)") is NOT tested here: the plan's Approach says the
       algorithm copies "the first match (name-sorted, deterministic)", and
       R9's own Behaviour names only two rejection scenarios (mismatched-
       path, closed-port) - nothing in the Approach describes continuing to
       evaluate/report a SECOND live candidate for the same project once one
       has already been adopted. Deferring this token rather than inventing
       scan-order behaviour the plan does not specify; flagged in the change
       report for confirmation during phase=implement.
#>

$global:uma_repoRoot      = Split-Path -Parent $PSScriptRoot
$global:uma_scriptPath    = Join-Path $global:uma_repoRoot 'scripts\unity-mcp-adopt.ps1'
$global:uma_hooksJsonPath = Join-Path $global:uma_repoRoot 'hooks\hooks.json'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function New-TempDir {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("uma-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    return $tmp
}
function Remove-TempDir { param($p) Remove-Item -Recurse -Force -Path $p -ErrorAction SilentlyContinue }

# Dot-sources the REAL script under test, with a clear thrown message when it
# is absent so every test's RED shows "not implemented yet" rather than a
# cryptic host parse error - this is the expected RED for R1-R5/R9 above.
function Import-UnityMcpAdoptScript {
    if (-not (Test-Path -LiteralPath $global:uma_scriptPath)) {
        throw "scripts/unity-mcp-adopt.ps1 does not exist yet (ticket #52 phase=implement not yet run)"
    }
    . $global:uma_scriptPath
}

function New-StatusFixture {
    param(
        [Parameter(Mandatory)][string]$GlobalStatusDir,
        [Parameter(Mandatory)]$ProjectPath,
        [Parameter(Mandatory)][int]$Port,
        [string]$NamePrefix = 'unity-mcp',
        [string]$HeartbeatIso = $null
    )
    New-Item -ItemType Directory -Force -Path $GlobalStatusDir | Out-Null
    $hb = if ($HeartbeatIso) { $HeartbeatIso } else { (Get-Date).ToUniversalTime().ToString('o') }
    $statusObj = [pscustomobject]@{
        project_path   = $ProjectPath
        unity_port     = $Port
        last_heartbeat = $hb
    }
    $statusFile = Join-Path $GlobalStatusDir "$NamePrefix-status-$Port.json"
    ($statusObj | ConvertTo-Json) | Set-Content -Path $statusFile -Encoding UTF8
    return $statusFile
}

function Start-FakeUnityListener {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    return @{ Listener = $listener; Port = $port }
}
function Stop-FakeUnityListener { param($h) if ($h -and $h.Listener) { try { $h.Listener.Stop() } catch { } } }

# ---------------------------------------------------------------------------
# R1 - a live Hub-started editor for an unprepared checkout is adopted, via
# the real script's entry point (as a PreToolUse hook or manual run would
# invoke it).
# ---------------------------------------------------------------------------
Describe 'unity-mcp-adopt.ps1 - adopts a live Hub-started editor for an unprepared checkout (ticket #52 / R1)' {

    It 'adopts a live Hub candidate in a checkout with no .seretos, ignoring a decoy for another project' {
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $fake = Start-FakeUnityListener
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port | Out-Null
            # decoy: a live status file for a DIFFERENT project - must not be copied.
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath 'C:\some\other\project\Assets' -Port 12345 -NamePrefix 'unity-mcp-decoy' | Out-Null

            $threw = $false
            try {
                & $global:uma_scriptPath -CheckoutPath $checkout -GlobalStatusDir $globalDir | Out-Null
            } catch { $threw = $true }

            # Expected RED: scripts/unity-mcp-adopt.ps1 does not exist yet.
            $threw | Should Be $false

            $statusDir = Join-Path $checkout '.unity-mcp'
            Test-Path $statusDir | Should Be $true
            $adopted = @(Get-ChildItem -Path $statusDir -Filter 'unity-mcp-status-adopted-*.json' -File -ErrorAction SilentlyContinue)
            $adopted.Count | Should Be 1
            # a real file, not a reparse point/symlink.
            (Get-Item -Force $adopted[0].FullName).LinkType | Should BeNullOrEmpty
            (Get-Content -LiteralPath $adopted[0].FullName -Raw | ConvertFrom-Json).unity_port | Should Be $fake.Port
            $adopted[0].Name | Should Not Match 'decoy'
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }

    It 'an absent global status dir produces no throw and creates no .unity-mcp dir' {
        $checkout  = New-TempDir
        $globalDir = Join-Path ([System.IO.Path]::GetTempPath()) ("uma-missing-" + [guid]::NewGuid())
        try {
            $threw = $false
            try {
                & $global:uma_scriptPath -CheckoutPath $checkout -GlobalStatusDir $globalDir | Out-Null
            } catch { $threw = $true }
            $threw | Should Be $false
            Test-Path (Join-Path $checkout '.unity-mcp') | Should Be $false
        } finally { Remove-TempDir $checkout }
    }

    It 'an empty global status dir produces no throw and creates no .unity-mcp dir' {
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        try {
            $threw = $false
            try {
                & $global:uma_scriptPath -CheckoutPath $checkout -GlobalStatusDir $globalDir | Out-Null
            } catch { $threw = $true }
            $threw | Should Be $false
            Test-Path (Join-Path $checkout '.unity-mcp') | Should Be $false
        } finally { Remove-TempDir $checkout; Remove-TempDir $globalDir }
    }
}

# ---------------------------------------------------------------------------
# R2 - matching is by normalized path, not literal string equality.
# ---------------------------------------------------------------------------
Describe 'Get-ComparablePath - normalizes before comparison (ticket #52 / R2)' {

    It 'separator, trailing-slash and dot-segment variants of the same path all normalize identically' {
        . Import-UnityMcpAdoptScript
        $checkout = New-TempDir
        try {
            $base = Join-Path $checkout 'Assets'
            # Deliberately NO case variant here (test-critic fix, note 5): the
            # plan scopes case-insensitivity to the COMPARISON
            # ([string]::Equals(...,'OrdinalIgnoreCase')), not the normalizer -
            # see the sibling "case difference is preserved" test below, and
            # Find-AdoptionCandidate's own case-differing-candidate test, which
            # exercises case-insensitivity at the right level (the comparison).
            $variants = @(
                $base,
                $base.Replace('\', '/'),
                ($base + '/'),
                (Join-Path $checkout 'Assets/x/..')
            )
            $normalized = @($variants | ForEach-Object { Get-ComparablePath -Path $_ })
            ($normalized | Select-Object -Unique).Count | Should Be 1
        } finally { Remove-TempDir $checkout }
    }

    It 'a case difference is preserved by the normalizer, not folded (test-critic fix, note 5 - resolution of plan-critique-adjacent scoping question)' {
        . Import-UnityMcpAdoptScript
        $checkout = New-TempDir
        try {
            $base = Join-Path $checkout 'Assets'
            # Case-sensitive (-cne) comparison on purpose: Get-ComparablePath
            # must NOT fold case (that belongs to Test-ComparablePathEquals /
            # the OrdinalIgnoreCase comparison used by Find-AdoptionCandidate),
            # so the upper-cased variant's normalized key must differ, byte
            # for byte, from the original-case key.
            ((Get-ComparablePath -Path $base) -cne (Get-ComparablePath -Path $base.ToUpper())) | Should Be $true
        } finally { Remove-TempDir $checkout }
    }

    It 'trims surrounding quotes before normalizing (resolution of plan-critique note 1)' {
        . Import-UnityMcpAdoptScript
        $checkout = New-TempDir
        try {
            $base   = Join-Path $checkout 'Assets'
            $quoted = '"' + $base + '"'
            (Get-ComparablePath -Path $quoted) | Should Be (Get-ComparablePath -Path $base)
        } finally { Remove-TempDir $checkout }
    }

    It 'a genuinely different directory does not normalize to the same key' {
        . Import-UnityMcpAdoptScript
        $checkout = New-TempDir
        try {
            $a = Join-Path $checkout 'Assets'
            $b = 'C:\genuinely\different\Assets'
            (Get-ComparablePath -Path $a) | Should Not Be (Get-ComparablePath -Path $b)
        } finally { Remove-TempDir $checkout }
    }
}

Describe 'Find-AdoptionCandidate - matches by normalized path, not literal string equality (ticket #52 / R2)' {

    It 'adopts a candidate whose project_path differs only in separator, case, trailing slash or a dot-segment' {
        . Import-UnityMcpAdoptScript
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $fake = Start-FakeUnityListener
            $base    = Join-Path $checkout 'Assets'
            # Deliberately mangled by manipulating the checkout's OWN path -
            # never re-emitting the same string on both sides.
            $mangled = ($base.Replace('\', '/').ToUpper()) + '/x/../'
            $fixture = New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath $mangled -Port $fake.Port

            $result = $null
            $threw = $false
            try { $result = Find-AdoptionCandidate -CheckoutPath $checkout -GlobalStatusDir $globalDir } catch { $threw = $true }

            # Expected RED: Find-AdoptionCandidate is not defined yet (script
            # absent) -> CommandNotFoundException / dot-source failure.
            $threw | Should Be $false
            $result | Should Not BeNullOrEmpty
            $result.StatusFile | Should Be $fixture
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }

    It 'a project_path wrapped in surrounding quotes, otherwise matching, is adopted (resolution of plan-critique note 1)' {
        . Import-UnityMcpAdoptScript
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $fake   = Start-FakeUnityListener
            $quoted = '"' + (Join-Path $checkout 'Assets') + '"'
            $fixture = New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath $quoted -Port $fake.Port

            $result = $null
            $threw = $false
            try { $result = Find-AdoptionCandidate -CheckoutPath $checkout -GlobalStatusDir $globalDir } catch { $threw = $true }

            $threw | Should Be $false
            $result | Should Not BeNullOrEmpty
            $result.StatusFile | Should Be $fixture
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }

    It 'a candidate under a genuinely different directory is not adopted (project_path mismatch)' {
        . Import-UnityMcpAdoptScript
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $fake = Start-FakeUnityListener
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath 'C:\genuinely\different\Assets' -Port $fake.Port | Out-Null

            $result = 'unset'
            $threw = $false
            try { $result = Find-AdoptionCandidate -CheckoutPath $checkout -GlobalStatusDir $globalDir } catch { $threw = $true }

            $threw | Should Be $false
            $result | Should Be $null
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }

    It 'an empty/whitespace project_path is rejected as unreadable, no throw (NOT the quoted case above)' {
        . Import-UnityMcpAdoptScript
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $fake = Start-FakeUnityListener
            New-Item -ItemType Directory -Force -Path $globalDir | Out-Null
            $badObj = [pscustomobject]@{
                project_path   = '   '
                unity_port     = $fake.Port
                last_heartbeat = (Get-Date).ToUniversalTime().ToString('o')
            }
            ($badObj | ConvertTo-Json) | Set-Content -Path (Join-Path $globalDir 'unity-mcp-status-bad.json') -Encoding UTF8

            $result = 'unset'
            $threw = $false
            # test-critic fix (note 6): assert the candidate is actually
            # REPORTED with reason token 'unreadable' via the -Diagnostics
            # collection, not just "result is null" - a wrong implementation
            # that silently skips the candidate for the WRONG reason (e.g. a
            # path-mismatch false positive) would still pass a null-only check.
            $diag = New-Object 'System.Collections.Generic.List[string]'
            try { $result = Find-AdoptionCandidate -CheckoutPath $checkout -GlobalStatusDir $globalDir -Diagnostics $diag } catch { $threw = $true }

            $threw | Should Be $false
            $result | Should Be $null
            ($diag -join "`n") | Should Match 'unreadable'
            @($diag | Where-Object { $_ -match 'unity-mcp-status-bad\.json' }).Count | Should Be 1
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }
}

# ---------------------------------------------------------------------------
# R3 - a dead adopted copy is removed; a live one survives; a closed-port
# candidate is never adopted; a live adopted copy + a live source is
# re-copied fresh.
# ---------------------------------------------------------------------------
Describe 'Invoke-UnityMcpAdoption - keeps a live adopted copy, deletes a dead one, does not adopt a closed-port candidate (ticket #52 / R3)' {

    It 'deletes a dead adopted copy whose port no longer answers' {
        . Import-UnityMcpAdoptScript
        $checkout = New-TempDir
        try {
            $statusDir = Join-Path $checkout '.unity-mcp'
            New-Item -ItemType Directory -Force -Path $statusDir | Out-Null
            $probe = Start-FakeUnityListener
            $deadPort = $probe.Port
            Stop-FakeUnityListener $probe
            $deadObj = [pscustomobject]@{
                project_path   = (Join-Path $checkout 'Assets')
                unity_port     = $deadPort
                last_heartbeat = (Get-Date).ToUniversalTime().ToString('o')
            }
            $deadFile = Join-Path $statusDir "unity-mcp-status-adopted-$deadPort.json"
            ($deadObj | ConvertTo-Json) | Set-Content -Path $deadFile -Encoding UTF8

            $emptyGlobal = New-TempDir
            $threw = $false
            try { Invoke-UnityMcpAdoption -CheckoutPath $checkout -GlobalStatusDir $emptyGlobal } catch { $threw = $true }
            $threw | Should Be $false

            # Expected RED: Invoke-UnityMcpAdoption is not defined yet.
            Test-Path $deadFile | Should Be $false
        } finally { Remove-TempDir $checkout }
    }

    It 'keeps a live adopted copy even when the global source is gone this run' {
        . Import-UnityMcpAdoptScript
        $checkout = New-TempDir
        $fake = $null
        try {
            $statusDir = Join-Path $checkout '.unity-mcp'
            New-Item -ItemType Directory -Force -Path $statusDir | Out-Null
            $fake = Start-FakeUnityListener
            $liveObj = [pscustomobject]@{
                project_path   = (Join-Path $checkout 'Assets')
                unity_port     = $fake.Port
                last_heartbeat = (Get-Date).ToUniversalTime().ToString('o')
            }
            $liveFile = Join-Path $statusDir "unity-mcp-status-adopted-$($fake.Port).json"
            ($liveObj | ConvertTo-Json) | Set-Content -Path $liveFile -Encoding UTF8
            $beforeContent = Get-Content -LiteralPath $liveFile -Raw

            $emptyGlobal = New-TempDir
            $threw = $false
            try { Invoke-UnityMcpAdoption -CheckoutPath $checkout -GlobalStatusDir $emptyGlobal } catch { $threw = $true }
            $threw | Should Be $false

            Test-Path $liveFile | Should Be $true
            (Get-Content -LiteralPath $liveFile -Raw) | Should Be $beforeContent
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
        }
    }

    It 'a closed-port global candidate is never adopted' {
        . Import-UnityMcpAdoptScript
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        try {
            $probe = Start-FakeUnityListener
            $closedPort = $probe.Port
            Stop-FakeUnityListener $probe
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $closedPort | Out-Null

            $threw = $false
            try { Invoke-UnityMcpAdoption -CheckoutPath $checkout -GlobalStatusDir $globalDir } catch { $threw = $true }
            $threw | Should Be $false

            $statusDir = Join-Path $checkout '.unity-mcp'
            if (Test-Path $statusDir) {
                @(Get-ChildItem -Path $statusDir -Filter 'unity-mcp-status-adopted-*.json' -File -ErrorAction SilentlyContinue).Count | Should Be 0
            }
        } finally { Remove-TempDir $checkout; Remove-TempDir $globalDir }
    }

    It 'a live adopted copy AND a live global source: re-copied fresh (content refreshed)' {
        . Import-UnityMcpAdoptScript
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $statusDir = Join-Path $checkout '.unity-mcp'
            New-Item -ItemType Directory -Force -Path $statusDir | Out-Null
            $fake = Start-FakeUnityListener

            # stale-content adopted copy already present (simulates a prior run).
            $staleObj = [pscustomobject]@{
                project_path   = (Join-Path $checkout 'Assets')
                unity_port     = $fake.Port
                last_heartbeat = '2000-01-01T00:00:00Z'
            }
            $adoptedFile = Join-Path $statusDir "unity-mcp-status-adopted-$($fake.Port).json"
            ($staleObj | ConvertTo-Json) | Set-Content -Path $adoptedFile -Encoding UTF8

            $freshHb = (Get-Date).ToUniversalTime().ToString('o')
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port -HeartbeatIso $freshHb | Out-Null

            $threw = $false
            try { Invoke-UnityMcpAdoption -CheckoutPath $checkout -GlobalStatusDir $globalDir } catch { $threw = $true }
            $threw | Should Be $false

            # Compare the raw text, not a JSON round-trip through
            # ConvertFrom-Json: PowerShell auto-detects an ISO-8601 "Z"
            # string and hands back an already-parsed [datetime], whose
            # sub-millisecond precision does not round-trip back through a
            # second parse of $freshHb identically - a false-negative trap
            # unrelated to what this test actually verifies (that the
            # adopted copy's on-disk CONTENT was refreshed).
            (Get-Content -LiteralPath $adoptedFile -Raw) | Should Match ([regex]::Escape($freshHb))
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }
}

# ---------------------------------------------------------------------------
# R4 - no hashed port file is required (the #52 second finding).
# ---------------------------------------------------------------------------
Describe 'Invoke-UnityMcpAdoption - no hashed port file is required (ticket #52 / R4)' {

    It 'adopts when only unity-mcp-status-<hash>.json exists, alongside an unhashed unity-mcp-port.json (Unity 10.1.2 shape)' {
        . Import-UnityMcpAdoptScript
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $fake = Start-FakeUnityListener
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port | Out-Null
            # Newer Unity packages write an UNHASHED port file - must be
            # irrelevant, never required, never copied.
            (@{ unity_port = $fake.Port } | ConvertTo-Json) | Set-Content -Path (Join-Path $globalDir 'unity-mcp-port.json') -Encoding UTF8

            $threw = $false
            try { Invoke-UnityMcpAdoption -CheckoutPath $checkout -GlobalStatusDir $globalDir } catch { $threw = $true }

            # Expected RED: against the pre-#52 (#47) approach, this fixture
            # would yield nothing (the hashed-port-file guard `continue`s).
            $threw | Should Be $false

            $statusDir = Join-Path $checkout '.unity-mcp'
            @(Get-ChildItem -Path $statusDir -Filter 'unity-mcp-status-adopted-*.json' -File).Count | Should Be 1
            @(Get-ChildItem -Path $statusDir -Filter '*port*' -File -ErrorAction SilentlyContinue).Count | Should Be 0
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }

    It 'adopts when no port file of any kind is present in the global dir' {
        . Import-UnityMcpAdoptScript
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        $fake = $null
        try {
            $fake = Start-FakeUnityListener
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fake.Port | Out-Null

            $threw = $false
            try { Invoke-UnityMcpAdoption -CheckoutPath $checkout -GlobalStatusDir $globalDir } catch { $threw = $true }
            $threw | Should Be $false

            $statusDir = Join-Path $checkout '.unity-mcp'
            @(Get-ChildItem -Path $statusDir -Filter 'unity-mcp-status-adopted-*.json' -File).Count | Should Be 1
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }
}

# ---------------------------------------------------------------------------
# R5 - the prepared/worktree case is untouched: a live real local instance
# short-circuits before any global-dir scan.
# ---------------------------------------------------------------------------
Describe 'Invoke-UnityMcpAdoption - a live real local instance short-circuits: global dir is not adopted from (ticket #52 / R5)' {

    It 'a live real unity-mcp-status-local.json means nothing is copied or deleted, even with a matching live global candidate' {
        . Import-UnityMcpAdoptScript
        $checkout   = New-TempDir
        $globalDir  = New-TempDir
        $fakeLocal  = $null
        $fakeGlobal = $null
        try {
            $statusDir = Join-Path $checkout '.unity-mcp'
            New-Item -ItemType Directory -Force -Path $statusDir | Out-Null
            $fakeLocal = Start-FakeUnityListener
            $localObj = [pscustomobject]@{
                project_path   = (Join-Path $checkout 'Assets')
                unity_port     = $fakeLocal.Port
                last_heartbeat = (Get-Date).ToUniversalTime().ToString('o')
            }
            $localFile = Join-Path $statusDir 'unity-mcp-status-local.json'
            ($localObj | ConvertTo-Json) | Set-Content -Path $localFile -Encoding UTF8
            $before = Get-Content -LiteralPath $localFile -Raw

            $fakeGlobal = Start-FakeUnityListener
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fakeGlobal.Port | Out-Null

            $threw = $false
            try { Invoke-UnityMcpAdoption -CheckoutPath $checkout -GlobalStatusDir $globalDir } catch { $threw = $true }
            $threw | Should Be $false

            (Get-Content -LiteralPath $localFile -Raw) | Should Be $before
            @(Get-ChildItem -Path $statusDir -Filter 'unity-mcp-status-adopted-*.json' -File -ErrorAction SilentlyContinue).Count | Should Be 0
        } finally {
            if ($fakeLocal) { Stop-FakeUnityListener $fakeLocal }
            if ($fakeGlobal) { Stop-FakeUnityListener $fakeGlobal }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }

    It 'a stale local file (port closed) + a live global candidate: adoption proceeds and the stale real file survives' {
        . Import-UnityMcpAdoptScript
        $checkout   = New-TempDir
        $globalDir  = New-TempDir
        $fakeGlobal = $null
        try {
            $statusDir = Join-Path $checkout '.unity-mcp'
            New-Item -ItemType Directory -Force -Path $statusDir | Out-Null
            $probe = Start-FakeUnityListener
            $closedPort = $probe.Port
            Stop-FakeUnityListener $probe
            $staleObj = [pscustomobject]@{
                project_path   = (Join-Path $checkout 'Assets')
                unity_port     = $closedPort
                last_heartbeat = (Get-Date).ToUniversalTime().ToString('o')
            }
            $staleFile = Join-Path $statusDir 'unity-mcp-status-local.json'
            ($staleObj | ConvertTo-Json) | Set-Content -Path $staleFile -Encoding UTF8

            $fakeGlobal = Start-FakeUnityListener
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $fakeGlobal.Port | Out-Null

            $threw = $false
            try { Invoke-UnityMcpAdoption -CheckoutPath $checkout -GlobalStatusDir $globalDir } catch { $threw = $true }
            $threw | Should Be $false

            Test-Path $staleFile | Should Be $true
            @(Get-ChildItem -Path $statusDir -Filter 'unity-mcp-status-adopted-*.json' -File).Count | Should Be 1
        } finally {
            if ($fakeGlobal) { Stop-FakeUnityListener $fakeGlobal }
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }
}

# ---------------------------------------------------------------------------
# R6 - the hook is registered as PreToolUse on the unityMCP tools and
# resolves to a real script.
# ---------------------------------------------------------------------------
Describe 'hooks/hooks.json - PreToolUse matcher fires on unityMCP tool names only (ticket #52 / R6)' {

    It 'declares PreToolUse (not SessionStart), resolves its command to a real file, and matches unityMCP tool names only' {
        Test-Path $global:uma_hooksJsonPath | Should Be $true
        $json = Get-Content -LiteralPath $global:uma_hooksJsonPath -Raw | ConvertFrom-Json

        # Expected RED: hooks.json still declares SessionStart with no matcher.
        ($json.hooks.PSObject.Properties.Name -contains 'PreToolUse') | Should Be $true
        ($json.hooks.PSObject.Properties.Name -contains 'SessionStart') | Should Be $false

        $entry   = $json.hooks.PreToolUse[0]
        $matcher = $entry.matcher
        $matcher | Should Not BeNullOrEmpty

        $commandText = ($entry.hooks | Out-String)
        $commandText | Should Match '\$\{CLAUDE_PLUGIN_ROOT\}'
        $null = $commandText -match '\$\{CLAUDE_PLUGIN_ROOT\}([^\s"'']+)'
        $relPath = $Matches[1]
        $relPath | Should Not BeNullOrEmpty
        $resolvedPath = Join-Path $global:uma_repoRoot ($relPath.TrimStart('/', '\') -replace '/', '\')
        Test-Path $resolvedPath | Should Be $true

        # test-critic fix (note 8): a bare "not null or empty" check would
        # pass for a timeout of "banana" or -1. Strengthen to an actual
        # bounded positive integer matching the plan's stated timeout: 10.
        $timeoutValue = $entry.hooks[0].timeout
        $timeoutInt = [int]$timeoutValue
        $timeoutInt | Should BeGreaterThan 0
        $timeoutInt | Should BeLessThan 31
        $timeoutValue | Should Be 10

        ('mcp__plugin_agent-unity-wrapper_unityMCP__manage_scene' -match $matcher) | Should Be $true
        ('mcp__unityMCP__read_console' -match $matcher) | Should Be $true
        ('Bash' -match $matcher) | Should Be $false
        ('mcp__plugin_x_serena__find_symbol' -match $matcher) | Should Be $false
    }
}

# ---------------------------------------------------------------------------
# R9 - rejected candidates are explained on stdout.
# ---------------------------------------------------------------------------
Describe 'Invoke-UnityMcpAdoption - rejected candidates are explained on stdout (ticket #52 / R9)' {

    It 'prints one line per rejected candidate, naming the file and reason; the mismatch line carries both normalized keys' {
        . Import-UnityMcpAdoptScript
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        try {
            # mismatched-path candidate
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath 'C:\genuinely\different\Assets' -Port 55001 -NamePrefix 'unity-mcp-mismatch' | Out-Null
            # closed-port candidate for the RIGHT project
            $probe = Start-FakeUnityListener
            $closedPort = $probe.Port
            Stop-FakeUnityListener $probe
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkout 'Assets') -Port $closedPort -NamePrefix 'unity-mcp-closed' | Out-Null

            $out = $null
            $threw = $false
            try { $out = (Invoke-UnityMcpAdoption -CheckoutPath $checkout -GlobalStatusDir $globalDir | Out-String) } catch { $threw = $true }

            # Expected RED: Invoke-UnityMcpAdoption is not defined yet -> no output at all.
            $threw | Should Be $false
            @($out -split "`n" | Where-Object { $_ -match 'unity-mcp-mismatch' }).Count | Should Be 1
            $out | Should Match 'project_path mismatch'
            $out | Should Match 'port closed'
            $mismatchLine = @($out -split "`n" | Where-Object { $_ -match 'project_path mismatch' })
            # test-critic fix (note 7): both normalized keys must appear - the
            # target's (so a human can compare) AND the rejected candidate's
            # own (per plan / R11 step 4: this is how a residual 8.3/junction
            # path difference becomes diagnosable from a real run's output).
            $mismatchLine[0] | Should Match ([regex]::Escape((Get-ComparablePath -Path (Join-Path $checkout 'Assets'))))
            $mismatchLine[0] | Should Match ([regex]::Escape((Get-ComparablePath -Path 'C:\genuinely\different\Assets')))
        } finally {
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }

    It 'zero candidates in the global dir produce no output and still exit without throwing' {
        . Import-UnityMcpAdoptScript
        $checkout  = New-TempDir
        $globalDir = New-TempDir
        try {
            $out = $null
            $threw = $false
            try { $out = (Invoke-UnityMcpAdoption -CheckoutPath $checkout -GlobalStatusDir $globalDir | Out-String) } catch { $threw = $true }
            $threw | Should Be $false
            $out.Trim() | Should Be ''
        } finally {
            Remove-TempDir $checkout
            Remove-TempDir $globalDir
        }
    }
}

# ---------------------------------------------------------------------------
# Test-critic fix (note 2): the plan requires the script's OWN exit code to be
# 0 even on an internal failure - it runs as a PreToolUse hook, which must
# never block a tool call. $LASTEXITCODE only reflects a real child-process
# invocation (not a dot-sourced call), so this forces a genuine internal
# failure (CheckoutPath is a FILE, not a directory, so once a live matching
# candidate forces the adoption path to create <CheckoutPath>/.unity-mcp,
# New-Item -ItemType Directory throws because its parent path segment is a
# file) and runs the real script as a child process to observe its exit code.
# ---------------------------------------------------------------------------
Describe 'unity-mcp-adopt.ps1 - always exits 0, even on an internal failure (ticket #52 / "always exits 0")' {

    It 'exits 0 when CheckoutPath is a file (forces New-Item -ItemType Directory to throw internally)' {
        $tmp = New-TempDir
        $checkoutFile = Join-Path $tmp 'not-a-directory.txt'
        Set-Content -Path $checkoutFile -Value 'x'
        $globalDir = New-TempDir
        $fake = $null
        try {
            $fake = Start-FakeUnityListener
            New-StatusFixture -GlobalStatusDir $globalDir -ProjectPath (Join-Path $checkoutFile 'Assets') -Port $fake.Port | Out-Null

            & powershell -NoProfile -File $global:uma_scriptPath -CheckoutPath $checkoutFile -GlobalStatusDir $globalDir *>&1 | Out-Null

            # Expected RED: scripts/unity-mcp-adopt.ps1 does not exist yet (or,
            # once it exists, if it is not wrapped in try/catch + exit 0, the
            # unhandled New-Item failure propagates and powershell.exe exits
            # non-zero).
            $LASTEXITCODE | Should Be 0
        } finally {
            if ($fake) { Stop-FakeUnityListener $fake }
            Remove-TempDir $tmp
            Remove-TempDir $globalDir
        }
    }
}
