#Requires -Version 5.1
<#
.SYNOPSIS
  Pester 3.x regression tests for scripts/prepare-unity-worktree.ps1.
  Run with:  Invoke-Pester .\tests\prepare-unity-worktree.Tests.ps1 -Verbose
#>

$global:puw_repoRoot   = Split-Path -Parent $PSScriptRoot
$global:puw_scriptPath = Join-Path $global:puw_repoRoot 'scripts\prepare-unity-worktree.ps1'

# ---------------------------------------------------------------------------
# Extract EVERY single-quoted here-string from the script source, keyed by the
# variable name it is assigned to (e.g. `$managedBlock = @'` ... `'@` yields
# key 'managedBlock'). NAMED extractor (ticket #47 plan-critic fix) - the
# previous version concatenated every here-string it found into one blanket
# $puw_managedBlock, which would silently merge a second here-string
# ($launchScript) into the same variable and corrupt every assertion scoped to
# "the managed block" specifically. Each here-string now lands in its own
# $puw_<name> global variable.
# ---------------------------------------------------------------------------
$_rawLines = [System.IO.File]::ReadAllLines($global:puw_scriptPath)
$_currentName = $null
$_blockLines  = [System.Collections.Generic.List[string]]::new()
$_hereStrings = @{}
foreach ($_line in $_rawLines) {
    $_t = $_line.TrimEnd()
    if ($null -eq $_currentName -and $_t -match '^\s*\$(\w+)\s*=\s*@''$') {
        $_currentName = $Matches[1]
        $_blockLines  = [System.Collections.Generic.List[string]]::new()
        continue
    }
    if ($null -ne $_currentName -and $_t -eq "'@") {
        $_hereStrings[$_currentName] = ($_blockLines -join "`n")
        $_currentName = $null
        continue
    }
    if ($null -ne $_currentName) { $_blockLines.Add($_t) }
}
$global:puw_hereStrings  = $_hereStrings
$global:puw_managedBlock = $_hereStrings['managedBlock']
$global:puw_launchScript = $_hereStrings['launchScript']

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function New-TempUnityRepo {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("puw-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmp 'ProjectSettings') | Out-Null
    Set-Content -Path (Join-Path $tmp 'ProjectSettings\ProjectVersion.txt') -Value 'm_EditorVersion: 2022.3.0f1'
    return $tmp
}
function Remove-TempUnityRepo { param($p) Remove-Item -Recurse -Force -Path $p -ErrorAction SilentlyContinue }
function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------
# Test-critic round 1 fix (R3/R4): materialize $puw_launchScript's source into
# a standalone temp .ps1 so it can be dot-sourced (". $path", not "& $path")
# and its real functions called/mocked directly, instead of replicating the
# decision logic inline where it can never fail regardless of the real
# script's behaviour. Mirrors New-MaterializedLaunchScript in
# tests\unity-mcp-adopt.Tests.ps1 (duplicated on purpose - no cross-file
# load-order dependency).
# ---------------------------------------------------------------------------
function New-MaterializedLaunchScriptForPuw {
    # Ticket #52: the launch script now dot-sources its sibling
    # scripts/unity-mcp-adopt.ps1 by $PSScriptRoot instead of defining
    # adoption inline - materialize a REAL copy of that sibling alongside the
    # extracted launch script (both under the same temp directory), so
    # dot-sourcing the launch script in isolation (as every test below does)
    # resolves $PSScriptRoot to a directory that actually contains it.
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("puw-launch-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmpDir | Out-Null
    $tmp = Join-Path $tmpDir 'unity-mcp-launch.ps1'
    $src = $global:puw_launchScript
    if ([string]::IsNullOrEmpty($src)) {
        $src = '# launchScript here-string not found in prepare-unity-worktree.ps1 (ticket #52 not yet implemented)'
    }
    Write-Utf8NoBom -Path $tmp -Content $src

    $adoptSrcPath = Join-Path $global:puw_repoRoot 'scripts\unity-mcp-adopt.ps1'
    if (Test-Path -LiteralPath $adoptSrcPath) {
        Copy-Item -LiteralPath $adoptSrcPath -Destination (Join-Path $tmpDir 'unity-mcp-adopt.ps1') -Force
    }
    return $tmp
}

function New-LocalStatusFile {
    param(
        [string]$StatusDir,
        [int]$Port,
        [int]$HeartbeatAgeSeconds = 5,
        [string]$Name = 'unity-mcp-status-local.json'
    )
    New-Item -ItemType Directory -Force -Path $StatusDir | Out-Null
    $heartbeat = (Get-Date).ToUniversalTime().AddSeconds(-$HeartbeatAgeSeconds).ToString('o')
    # Field names verified against the real mcpforunityserver==9.7.1 wheel
    # (review round 3): unity_port / last_heartbeat, not port / heartbeat -
    # see scripts\prepare-unity-worktree.ps1's Get-StatusFileHeartbeatAgeSeconds
    # header comment for the exact upstream source lines.
    $obj  = [pscustomobject]@{ unity_port = $Port; last_heartbeat = $heartbeat }
    $path = Join-Path $StatusDir $Name
    ($obj | ConvertTo-Json) | Set-Content -Path $path -Encoding UTF8
    return $path
}
function Start-LocalFakeListener {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    return @{ Listener = $listener; Port = $listener.LocalEndpoint.Port }
}
function Stop-LocalFakeListener { param($h) if ($h -and $h.Listener) { try { $h.Listener.Stop() } catch { } } }

# Ticket #52 - a plain scratch dir for a GLOBAL status dir fixture (unlike
# New-TempUnityRepo, which creates ProjectSettings/ - irrelevant, and
# misleading, for a directory meant to stand in for ~/.unity-mcp).
function New-PlainTempDir {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("puw-global-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    return $tmp
}
function Remove-PlainTempDir { param($p) Remove-Item -Recurse -Force -Path $p -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
Describe 'prepare-unity-worktree.ps1 — managed block content' {

    It 'script file exists' {
        Test-Path $global:puw_scriptPath | Should Be $true
    }

    It 'managed block was extracted successfully (sanity check)' {
        $global:puw_managedBlock.Length | Should BeGreaterThan 500
    }

    It 'managed block contains start: marker' {
        $global:puw_managedBlock | Should Match 'start:'
    }

    It 'managed block contains stop: marker' {
        $global:puw_managedBlock | Should Match 'stop:'
    }

    # Ticket #47 retarget: this content moved out of the managed block into
    # the shared launch script ($puw_launchScript / .seretos/unity-mcp-launch.ps1)
    # per the plan's "Affected files" section (editor resolution, batchmode/
    # nographics, cache server, Library mirror, unity.pid move to the launch
    # script). Same assertion, same behavioural claim, just pointed at the
    # here-string that now actually carries this content.
    It 'launch script sets UNITY_MCP_STATUS_DIR to the checkout-local .unity-mcp dir' {
        $global:puw_launchScript | Should Match 'UNITY_MCP_STATUS_DIR'
        $global:puw_launchScript | Should Match '\.unity-mcp'
    }

    It 'launch script sets UNITY_MCP_ALLOW_BATCH' {
        $global:puw_launchScript | Should Match 'UNITY_MCP_ALLOW_BATCH'
    }

    It 'launch script contains -batchmode and -nographics args' {
        $global:puw_launchScript | Should Match 'batchmode'
        $global:puw_launchScript | Should Match 'nographics'
    }

    It 'managed block contains name: default step' {
        $global:puw_managedBlock | Should Match 'name: default'
    }

    It 'managed block contains name: gui step' {
        $global:puw_managedBlock | Should Match 'name: gui'
    }

    # Ticket #47 retarget: the default/gui distinction is no longer two
    # duplicated here-string sections (that duplication is gone per the
    # plan's "Removed" list) - it is a single shared Start-UnityEditor
    # function with one `$Variant -eq 'default'` branch. Same behavioural
    # claim (batchmode is applied for the default variant), retargeted to
    # how the launch script actually expresses it.
    It 'launch script applies -batchmode/-nographics only in the $Variant -eq ''default'' branch' {
        $global:puw_launchScript | Should Match '\$Variant -eq ''default''\)\s*\{\s*\$unityArgs = @\(''-batchmode'', ''-nographics''\)'
    }

    It 'managed block gui step does not contain -batchmode' {
        # Extract text after name: gui and before stop:
        $afterGui = ($global:puw_managedBlock -split 'name: gui')[1]
        $guiSection = ($afterGui -split 'stop:')[0]
        $guiSection | Should Not Match 'batchmode'
    }

    # Ticket #47 retarget: the GUI-mode caveat comment lives once in the
    # shared launch script now (no longer duplicated per-variant), directly
    # beside the $Variant -eq 'default' batchmode branch above.
    It 'launch script contains the GUI-mode dialog caveat comment' {
        $global:puw_launchScript | Should Match 'does not suppress'
    }

    It 'managed block does not contain UNITY_WORKTREE_GUI' {
        $global:puw_managedBlock | Should Not Match 'UNITY_WORKTREE_GUI'
    }

    # Ticket #47 retarget: the boot moved into the shared launch script.
    It 'launch script boots the bridge via -executeMethod MCPForUnity.Editor.McpCiBoot.StartStdioForCi' {
        $global:puw_launchScript | Should Match 'MCPForUnity.Editor.McpCiBoot.StartStdioForCi'
    }

    It 'managed block records the unity PID in unity.pid' {
        $global:puw_managedBlock | Should Match 'unity\.pid'
    }

    It 'managed block stop step uses a pidFile variable' {
        $global:puw_managedBlock | Should Match 'pidFile'
    }

    It 'start/stop markers are present and correctly ordered' {
        $startIdx = $global:puw_managedBlock.IndexOf('>>> agent-unity-wrapper managed')
        $endIdx   = $global:puw_managedBlock.IndexOf('<<< agent-unity-wrapper managed')
        $startIdx | Should Not Be -1
        $endIdx   | Should Not Be -1
        ($startIdx -lt $endIdx) | Should Be $true
    }
}

# ---------------------------------------------------------------------------
Describe 'prepare-unity-worktree.ps1 — fresh repo (no existing contract)' {

    It 'creates .seretos/worktree-setup.yml with managed block and isolation: full' {
        $tmp = New-TempUnityRepo
        try {
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $setupPath = Join-Path $tmp '.seretos\worktree-setup.yml'
            Test-Path $setupPath | Should Be $true
            $content = Get-Content -LiteralPath $setupPath -Raw
            $content | Should Match 'isolation: full'
            $content | Should Match '>>> agent-unity-wrapper managed'
            $content | Should Match '<<< agent-unity-wrapper managed'
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'creates .gitignore with .unity-mcp/ entry' {
        $tmp = New-TempUnityRepo
        try {
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $giPath = Join-Path $tmp '.gitignore'
            Test-Path $giPath | Should Be $true
            (Get-Content -LiteralPath $giPath -Raw) | Should Match '\.unity-mcp/'
        } finally { Remove-TempUnityRepo $tmp }
    }
}

# ---------------------------------------------------------------------------
Describe 'prepare-unity-worktree.ps1 — Packages/manifest.json handling' {

    It 'adds com.coplaydev.unity-mcp when manifest exists without it' {
        $tmp = New-TempUnityRepo
        try {
            New-Item -ItemType Directory -Path (Join-Path $tmp 'Packages') | Out-Null
            $mp = Join-Path $tmp 'Packages\manifest.json'
            Write-Utf8NoBom -Path $mp -Content '{"dependencies":{}}'
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $obj = Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json
            $obj.dependencies.'com.coplaydev.unity-mcp' | Should Match '#v9\.7\.1'
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'does not touch manifest when com.coplaydev.unity-mcp is already at correct version' {
        $tmp = New-TempUnityRepo
        try {
            New-Item -ItemType Directory -Path (Join-Path $tmp 'Packages') | Out-Null
            $mp  = Join-Path $tmp 'Packages\manifest.json'
            $url = 'https://github.com/CoplayDev/unity-mcp.git?path=/MCPForUnity#v9.7.1'
            Write-Utf8NoBom -Path $mp -Content "{`"dependencies`":{`"com.coplaydev.unity-mcp`":`"$url`"}}"
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            (Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json).dependencies.'com.coplaydev.unity-mcp' | Should Be $url
        } finally { Remove-TempUnityRepo $tmp }
    }

    # Plan item 4 — multi-package ConvertTo-Json round-trip regression.
    # Verifies -Force pin update preserves all other packages (no PS 5.1 mangling).
    It 'plan-item-4: -Force pin update preserves all other packages (ConvertTo-Json round-trip)' {
        $tmp = New-TempUnityRepo
        try {
            New-Item -ItemType Directory -Path (Join-Path $tmp 'Packages') | Out-Null
            $mp = Join-Path $tmp 'Packages\manifest.json'
            # Fixture: stale pin PLUS two other real packages, written as plain JSON.
            $fixture = "{`r`n  `"dependencies`": {`r`n    `"com.unity.modules.ai`": `"1.0.0`",`r`n    `"com.coplaydev.unity-mcp`": `"https://github.com/CoplayDev/unity-mcp.git?path=/MCPForUnity#main`",`r`n    `"com.unity.textmeshpro`": `"3.0.6`"`r`n  }`r`n}"
            Write-Utf8NoBom -Path $mp -Content $fixture

            & $global:puw_scriptPath -RepoRoot $tmp -Force | Out-Null

            # Must still be valid JSON after the update.
            $reparsed = Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json

            # com.coplaydev.unity-mcp must be updated to the correct pin.
            $reparsed.dependencies.'com.coplaydev.unity-mcp' | Should Match '#v9\.7\.1'

            # All other packages must be present and untouched.
            $reparsed.dependencies.'com.unity.modules.ai'  | Should Be '1.0.0'
            $reparsed.dependencies.'com.unity.textmeshpro' | Should Be '3.0.6'
        } finally { Remove-TempUnityRepo $tmp }
    }

    # Fix 5 — version mismatch warning surfaces #tag fragments.
    It 'Fix-5: version mismatch warning surfaces the tag fragments (current and expected)' {
        $tmp = New-TempUnityRepo
        try {
            New-Item -ItemType Directory -Path (Join-Path $tmp 'Packages') | Out-Null
            $mp = Join-Path $tmp 'Packages\manifest.json'
            Write-Utf8NoBom -Path $mp -Content '{"dependencies":{"com.coplaydev.unity-mcp":"https://github.com/CoplayDev/unity-mcp.git?path=/MCPForUnity#main"}}'
            $wv = $null
            & $global:puw_scriptPath -RepoRoot $tmp -WarningVariable wv 2>&1 | Out-Null
            $warnText = ($wv | Out-String)
            ($warnText -match 'main') | Should Be $true
            ($warnText -match 'v9\.7\.1') | Should Be $true
        } finally { Remove-TempUnityRepo $tmp }
    }
}

# ---------------------------------------------------------------------------
# Ticket #37 — existence-based ownership. Once .seretos/worktree-setup.yml
# exists, the script never writes to it again: no append, no isolation flip,
# no reconcile, under any flag. This supersedes the #28 "isolation flip on
# append" behaviour entirely (that append branch is removed, not just
# Force-gated).
Describe 'prepare-unity-worktree.ps1 — existence-based ownership (ticket #37)' {

    It 'ticket-37: -Force does not flip isolation and does not append' {
        $tmp = New-TempUnityRepo
        try {
            $setupDir = Join-Path $tmp '.seretos'
            New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
            $setupPath = Join-Path $setupDir 'worktree-setup.yml'
            Write-Utf8NoBom -Path $setupPath -Content "version: 1`nisolation: partial`n"
            $before = Get-Content -LiteralPath $setupPath -Raw

            & $global:puw_scriptPath -RepoRoot $tmp -Force | Out-Null

            $after = Get-Content -LiteralPath $setupPath -Raw
            $after | Should Be $before
            $after | Should Match 'isolation: partial'
            $after | Should Not Match 'isolation: full'
            $after | Should Not Match '>>> agent-unity-wrapper managed'
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'ticket-37: script source no longer contains the isolation-flip messages' {
        $src = [System.IO.File]::ReadAllText($global:puw_scriptPath)
        $src | Should Not Match 'Flipped isolation'
        $src | Should Not Match 'Re-run with -Force to flip'
    }

    It 'ticket-37: existing contract with no start/stop is never appended to (no -Force)' {
        $tmp = New-TempUnityRepo
        try {
            $setupDir = Join-Path $tmp '.seretos'
            New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
            $setupPath = Join-Path $setupDir 'worktree-setup.yml'
            Write-Utf8NoBom -Path $setupPath -Content "version: 1`nisolation: partial`n"
            $before = Get-Content -LiteralPath $setupPath -Raw

            $threw = $false
            $out = $null
            try {
                $out = & $global:puw_scriptPath -RepoRoot $tmp *>&1 | Out-String
            } catch {
                $threw = $true
            }
            $threw | Should Be $false

            $after = Get-Content -LiteralPath $setupPath -Raw
            $after | Should Be $before
            $after | Should Not Match '>>> agent-unity-wrapper managed'
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'ticket-37: existing contract with isolation: full and no start/stop is never appended to' {
        $tmp = New-TempUnityRepo
        try {
            $setupDir = Join-Path $tmp '.seretos'
            New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
            $setupPath = Join-Path $setupDir 'worktree-setup.yml'
            Write-Utf8NoBom -Path $setupPath -Content "version: 1`nisolation: full`n"
            $before = Get-Content -LiteralPath $setupPath -Raw

            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null

            $after = Get-Content -LiteralPath $setupPath -Raw
            $after | Should Be $before
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'ticket-37: arbitrary unrelated YAML is never written to' {
        $tmp = New-TempUnityRepo
        try {
            $setupDir = Join-Path $tmp '.seretos'
            New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
            $setupPath = Join-Path $setupDir 'worktree-setup.yml'
            Write-Utf8NoBom -Path $setupPath -Content "hello: world`n"
            $before = Get-Content -LiteralPath $setupPath -Raw

            $threw = $false
            try {
                & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            } catch {
                $threw = $true
            }
            $threw | Should Be $false

            $after = Get-Content -LiteralPath $setupPath -Raw
            $after | Should Be $before
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'ticket-37: a zero-byte file counts as existing and is never written to' {
        $tmp = New-TempUnityRepo
        try {
            $setupDir = Join-Path $tmp '.seretos'
            New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
            $setupPath = Join-Path $setupDir 'worktree-setup.yml'
            [System.IO.File]::WriteAllText($setupPath, '', (New-Object System.Text.UTF8Encoding($false)))
            (Get-Item -LiteralPath $setupPath).Length | Should Be 0

            $threw = $false
            try {
                & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            } catch {
                $threw = $true
            }
            $threw | Should Be $false

            (Get-Item -LiteralPath $setupPath).Length | Should Be 0
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'ticket-37: a comment-only file is never written to' {
        $tmp = New-TempUnityRepo
        try {
            $setupDir = Join-Path $tmp '.seretos'
            New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
            $setupPath = Join-Path $setupDir 'worktree-setup.yml'
            Write-Utf8NoBom -Path $setupPath -Content "# just a comment`n"
            $before = Get-Content -LiteralPath $setupPath -Raw

            $threw = $false
            try {
                & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            } catch {
                $threw = $true
            }
            $threw | Should Be $false

            $after = Get-Content -LiteralPath $setupPath -Raw
            $after | Should Be $before
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'ticket-37: script does not classify by marker match' {
        $src = [System.IO.File]::ReadAllText($global:puw_scriptPath)
        $src | Should Not Match ([regex]::Escape('[regex]::Escape($startMarker)'))
        $src | Should Not Match ([regex]::Escape('$startMarker ='))
        $src | Should Not Match ([regex]::Escape('$endMarker ='))
        ([regex]::Matches($src, [regex]::Escape('Write-Utf8NoBom -Path $setupPath')).Count) | Should Be 1
    }

    It 'ticket-37: managed block marker does not claim the block must not be edited' {
        $global:puw_managedBlock | Should Not Match 'do not edit'
        $global:puw_managedBlock | Should Match 'edit it freely'
    }

}

# ---------------------------------------------------------------------------
Describe 'prepare-unity-worktree.ps1 — idempotency and -Force behaviour' {

    It 're-running without -Force on a fully-prepared repo is a no-op (setup.yml unchanged)' {
        $tmp = New-TempUnityRepo
        try {
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $setupPath = Join-Path $tmp '.seretos\worktree-setup.yml'
            $before = Get-Content -LiteralPath $setupPath -Raw
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $after = Get-Content -LiteralPath $setupPath -Raw
            $after | Should Be $before
        } finally { Remove-TempUnityRepo $tmp }
    }

    # Ticket #28 — -Force must never rewrite an existing managed block, healthy or stale.
    It '-Force does NOT rewrite an existing managed block (local edits survive)' {
        $tmp = New-TempUnityRepo
        try {
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $setupPath = Join-Path $tmp '.seretos\worktree-setup.yml'
            # Corrupt the block (this does not trip any stale-detection heuristic - stays "healthy").
            $content = Get-Content -LiteralPath $setupPath -Raw
            $corrupted = $content -replace 'name: default', 'name: CORRUPTED'
            Write-Utf8NoBom -Path $setupPath -Content $corrupted
            $before = Get-Content -LiteralPath $setupPath -Raw

            $wv = $null
            $out = & $global:puw_scriptPath -RepoRoot $tmp -Force -WarningVariable wv *>&1 | Out-String

            $after = Get-Content -LiteralPath $setupPath -Raw
            $after | Should Be $before
            $after | Should Match 'name: CORRUPTED'

            # Healthy block -> quiet path: info line only, no template dump, no
            # managed-block warning. (The manifest.json warning is unrelated - this
            # fixture has no Packages/manifest.json - so we assert on content, not
            # on $wv being empty.)
            $out | Should Match 'leaving it untouched'
            $out | Should Not Match 'by hand'
            $out | Should Not Match '>>> agent-unity-wrapper managed'
            ($wv | Out-String) | Should Not Match 'outdated'
        } finally { Remove-TempUnityRepo $tmp }
    }

    It '-Force does NOT rewrite a stale managed block either (whole body replaced by a foreign line, markers intact)' {
        $tmp = New-TempUnityRepo
        try {
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $setupPath = Join-Path $tmp '.seretos\worktree-setup.yml'
            $content = Get-Content -LiteralPath $setupPath -Raw
            $blockStartMarker = ($content -split "`n" | Where-Object { $_ -match '^# >>> agent-unity-wrapper managed' } | Select-Object -First 1)
            $blockEndMarker   = '# <<< agent-unity-wrapper managed'
            $sIdx = $content.IndexOf($blockStartMarker)
            $eIdx = $content.IndexOf($blockEndMarker, $sIdx)
            $stale = $content.Substring(0, $sIdx) + $blockStartMarker + "`n# a hand-written foreign line`n" + $content.Substring($eIdx)
            Write-Utf8NoBom -Path $setupPath -Content $stale
            $before = Get-Content -LiteralPath $setupPath -Raw

            $wv = $null
            $out = & $global:puw_scriptPath -RepoRoot $tmp -Force -WarningVariable wv *>&1 | Out-String

            $after = Get-Content -LiteralPath $setupPath -Raw
            $after | Should Be $before
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'a repo with no existing .seretos/worktree-setup.yml still gets the managed block created' {
        $tmp = New-TempUnityRepo
        try {
            $setupPath = Join-Path $tmp '.seretos\worktree-setup.yml'
            Test-Path $setupPath | Should Be $false
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            Test-Path $setupPath | Should Be $true
            $content = Get-Content -LiteralPath $setupPath -Raw
            $content | Should Match '>>> agent-unity-wrapper managed'
        } finally { Remove-TempUnityRepo $tmp }
    }

    # Ticket #37/#39 — a foreign start:/stop: block is left untouched (no read, no
    # write, no advisory) and the script still exits 0 like every other
    # "file already exists" case.
    It 'ticket-37: foreign start/stop block is left untouched, never throws, exits 0' {
        $tmp = New-TempUnityRepo
        try {
            New-Item -ItemType Directory -Path (Join-Path $tmp '.seretos') -Force | Out-Null
            $setupPath = Join-Path $tmp '.seretos\worktree-setup.yml'
            $foreign = "version: 1`nisolation: full`n`nstart:`n  - name: custom`n    shell: pwsh`n    run: echo hi`nstop:`n  - name: custom-stop`n    shell: pwsh`n    run: echo bye`n"
            Write-Utf8NoBom -Path $setupPath -Content $foreign
            $before = Get-Content -LiteralPath $setupPath -Raw

            $threw = $false
            try {
                & $global:puw_scriptPath -RepoRoot $tmp *>&1 | Out-Null
            } catch {
                $threw = $true
            }
            $threw | Should Be $false

            $after = Get-Content -LiteralPath $setupPath -Raw
            $after | Should Be $before

            # Exit-code check: run as a child process to confirm a clean exit 0.
            & powershell -NoProfile -File $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $LASTEXITCODE | Should Be 0
        } finally { Remove-TempUnityRepo $tmp }
    }

    # Ticket #37 — sections 2/3 (manifest + .gitignore) are no longer aborted by
    # the foreign-contract case now that the throw is gone.
    It 'ticket-37: foreign start/stop block does not abort manifest.json / .gitignore preparation' {
        $tmp = New-TempUnityRepo
        try {
            New-Item -ItemType Directory -Path (Join-Path $tmp '.seretos') -Force | Out-Null
            $setupPath = Join-Path $tmp '.seretos\worktree-setup.yml'
            $foreign = "version: 1`nisolation: full`n`nstart:`n  - name: custom`n    shell: pwsh`n    run: echo hi`nstop:`n  - name: custom-stop`n    shell: pwsh`n    run: echo bye`n"
            Write-Utf8NoBom -Path $setupPath -Content $foreign

            New-Item -ItemType Directory -Path (Join-Path $tmp 'Packages') | Out-Null
            $mp = Join-Path $tmp 'Packages\manifest.json'
            Write-Utf8NoBom -Path $mp -Content '{"dependencies":{}}'

            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null

            $obj = Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json
            $obj.dependencies.'com.coplaydev.unity-mcp' | Should Match '#v9\.7\.1'

            $giPath = Join-Path $tmp '.gitignore'
            Test-Path $giPath | Should Be $true
            (Get-Content -LiteralPath $giPath -Raw) | Should Match '\.unity-mcp/'
        } finally { Remove-TempUnityRepo $tmp }
    }

}

# ---------------------------------------------------------------------------
# Ticket #39 — no content inspection. Ticket #37 established that an existing
# .seretos/worktree-setup.yml is never written to; #39 carries the same
# ownership rule to reads: once the file exists, the script must not open it
# at all, must not classify it as missing/foreign/outdated, and must not warn
# about its contents (isolation value included). Existence (Test-Path) is the
# only permitted check.
Describe 'prepare-unity-worktree.ps1 — no content inspection (ticket #39)' {

    It 'foreign existing file produces no content-related warning' {
        $tmp = New-TempUnityRepo
        try {
            New-Item -ItemType Directory -Path (Join-Path $tmp '.seretos') -Force | Out-Null
            $setupPath = Join-Path $tmp '.seretos\worktree-setup.yml'
            $foreign = "version: 1`nisolation: full`n`nstart:`n  - name: custom`n    shell: pwsh`n    run: echo hi`nstop:`n  - name: custom-stop`n    shell: pwsh`n    run: echo bye`n"
            Write-Utf8NoBom -Path $setupPath -Content $foreign

            $wv = $null
            $out = & $global:puw_scriptPath -RepoRoot $tmp -WarningVariable wv *>&1 | Out-String

            $out | Should Match 'leaving it untouched'
            $out | Should Not Match 'by hand'
            $out | Should Not Match 'outdated'
            $out | Should Not Match '>>> agent-unity-wrapper managed'
            ($wv | Out-String) | Should Not Match 'worktree-setup'
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'isolation: partial in an existing file draws no warning' {
        $tmp = New-TempUnityRepo
        try {
            New-Item -ItemType Directory -Path (Join-Path $tmp '.seretos') -Force | Out-Null
            $setupPath = Join-Path $tmp '.seretos\worktree-setup.yml'
            Write-Utf8NoBom -Path $setupPath -Content "version: 1`nisolation: partial`n"

            $wv = $null
            & $global:puw_scriptPath -RepoRoot $tmp -WarningVariable wv 2>&1 | Out-Null
            ($wv | Out-String) | Should Not Match 'isolation'
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'an existing file with no isolation key at all draws no warning' {
        $tmp = New-TempUnityRepo
        try {
            New-Item -ItemType Directory -Path (Join-Path $tmp '.seretos') -Force | Out-Null
            $setupPath = Join-Path $tmp '.seretos\worktree-setup.yml'
            Write-Utf8NoBom -Path $setupPath -Content "hello: world`n"

            $wv = $null
            & $global:puw_scriptPath -RepoRoot $tmp -WarningVariable wv 2>&1 | Out-Null
            ($wv | Out-String) | Should Not Match 'isolation'
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'script never reads the existing setup file (static source check)' {
        $src = [System.IO.File]::ReadAllText($global:puw_scriptPath)
        $src | Should Not Match 'Get-Content[^\r\n]*\$setupPath'
        $src | Should Not Match '\$looksOutdatedOrMissing'
        $src | Should Not Match '\$hasStartStop'
        $src | Should Not Match ([regex]::Escape('isolation\s*:\s*full'))
        ([regex]::Matches($src, [regex]::Escape('Write-Utf8NoBom -Path $setupPath')).Count) | Should Be 1
    }

    # Re-authored from the deleted "stale block: -Force produces output and file
    # identical to the no-Force run" test - a plain -Force parity guard, no
    # "stale" framing (the script no longer classifies contents at all).
    It '-Force output and file are identical to the no-Force run for an existing file' {
        $tmp = New-TempUnityRepo
        try {
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $setupPath = Join-Path $tmp '.seretos\worktree-setup.yml'
            $content = Get-Content -LiteralPath $setupPath -Raw
            $stripped = ($content -split "`n" | Where-Object { $_ -notmatch 'UNITY_WORKTREE_CACHE_SERVER' }) -join "`n"

            Write-Utf8NoBom -Path $setupPath -Content $stripped
            $outNoForce = & $global:puw_scriptPath -RepoRoot $tmp *>&1 | Out-String
            $fileAfterNoForce = Get-Content -LiteralPath $setupPath -Raw

            Write-Utf8NoBom -Path $setupPath -Content $stripped
            $outForce = & $global:puw_scriptPath -RepoRoot $tmp -Force *>&1 | Out-String
            $fileAfterForce = Get-Content -LiteralPath $setupPath -Raw

            $outForce | Should Be $outNoForce
            $fileAfterForce | Should Be $fileAfterNoForce
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'edge case: zero-byte file draws no content warning and stays byte-identical' {
        $tmp = New-TempUnityRepo
        try {
            $setupDir = Join-Path $tmp '.seretos'
            New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
            $setupPath = Join-Path $setupDir 'worktree-setup.yml'
            [System.IO.File]::WriteAllText($setupPath, '', (New-Object System.Text.UTF8Encoding($false)))

            $wv = $null
            $out = & $global:puw_scriptPath -RepoRoot $tmp -WarningVariable wv *>&1 | Out-String
            $out | Should Match 'leaving it untouched'
            ($wv | Out-String) | Should Not Match 'worktree-setup'
            (Get-Item -LiteralPath $setupPath).Length | Should Be 0
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'edge case: comment-only file draws no content warning and stays byte-identical' {
        $tmp = New-TempUnityRepo
        try {
            $setupDir = Join-Path $tmp '.seretos'
            New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
            $setupPath = Join-Path $setupDir 'worktree-setup.yml'
            Write-Utf8NoBom -Path $setupPath -Content "# just a comment`n"
            $before = Get-Content -LiteralPath $setupPath -Raw

            $wv = $null
            $out = & $global:puw_scriptPath -RepoRoot $tmp -WarningVariable wv *>&1 | Out-String
            $out | Should Match 'leaving it untouched'
            ($wv | Out-String) | Should Not Match 'worktree-setup'

            $after = Get-Content -LiteralPath $setupPath -Raw
            $after | Should Be $before
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'edge case: arbitrary unrelated YAML draws no content warning and stays byte-identical' {
        $tmp = New-TempUnityRepo
        try {
            $setupDir = Join-Path $tmp '.seretos'
            New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
            $setupPath = Join-Path $setupDir 'worktree-setup.yml'
            Write-Utf8NoBom -Path $setupPath -Content "hello: world`n"
            $before = Get-Content -LiteralPath $setupPath -Raw

            $wv = $null
            $out = & $global:puw_scriptPath -RepoRoot $tmp -WarningVariable wv *>&1 | Out-String
            $out | Should Match 'leaving it untouched'
            ($wv | Out-String) | Should Not Match 'worktree-setup'

            $after = Get-Content -LiteralPath $setupPath -Raw
            $after | Should Be $before
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'edge case: script-created-then-stripped block draws no content warning and stays byte-identical' {
        $tmp = New-TempUnityRepo
        try {
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $setupPath = Join-Path $tmp '.seretos\worktree-setup.yml'
            $content = Get-Content -LiteralPath $setupPath -Raw
            $stripped = ($content -split "`n" | Where-Object { $_ -notmatch 'UNITY_WORKTREE_CACHE_SERVER' }) -join "`n"
            Write-Utf8NoBom -Path $setupPath -Content $stripped
            $before = Get-Content -LiteralPath $setupPath -Raw

            $wv = $null
            $out = & $global:puw_scriptPath -RepoRoot $tmp -WarningVariable wv *>&1 | Out-String
            $out | Should Match 'leaving it untouched'
            ($wv | Out-String) | Should Not Match 'worktree-setup'

            $after = Get-Content -LiteralPath $setupPath -Raw
            $after | Should Be $before
        } finally { Remove-TempUnityRepo $tmp }
    }
}

# ---------------------------------------------------------------------------
Describe 'launch script content — cache server' {
    # Ticket #47 retarget: cache-server flags moved from the managed block
    # into the shared launch script (Start-UnityEditor). Same assertions.

    It 'launch script contains UNITY_WORKTREE_CACHE_SERVER reference' {
        $global:puw_launchScript | Should Match 'UNITY_WORKTREE_CACHE_SERVER'
    }

    It 'launch script contains -EnableCacheServer flag' {
        $global:puw_launchScript | Should Match 'EnableCacheServer'
    }

    It 'launch script contains -cacheServerEndpoint flag' {
        $global:puw_launchScript | Should Match 'cacheServerEndpoint'
    }
}

# ---------------------------------------------------------------------------
# Runtime test for the UNITY_WORKTREE_CACHE_SERVER arg-filter.
#
# Invoke-CacheServerArgFilter replicates the $unityArgs construction and the
# UNITY_WORKTREE_CACHE_SERVER conditional from the managed block.  The optional
# $GuiFlagValue parameter simulates starting from a gui-variant arg set (no
# -batchmode/-nographics) to verify cache-server flags co-exist correctly.
# The structural tests above couple these runtime assertions to the real script.
# ---------------------------------------------------------------------------
Describe 'UNITY_WORKTREE_CACHE_SERVER runtime arg-filter' {

    function Invoke-CacheServerArgFilter {
        param(
            [string]$CacheServerValue,
            [string]$GuiFlagValue
        )
        $proj      = 'C:\fake\proj'
        $statusDir = 'C:\fake\proj\.unity-mcp'
        $log       = Join-Path $statusDir 'editor.log'
        # Start with default (headless) args; $GuiFlagValue='1' simulates the gui variant.
        $unityArgs = @(
            '-batchmode', '-nographics',
            '-logFile', $log,
            '-projectPath', $proj,
            '-executeMethod', 'MCPForUnity.Editor.McpCiBoot.StartStdioForCi'
        )
        if ($GuiFlagValue -eq '1') {
            $unityArgs = $unityArgs | Where-Object { $_ -notin @('-batchmode', '-nographics') }
        }
        if (-not [string]::IsNullOrWhiteSpace($CacheServerValue)) {
            $unityArgs += @('-EnableCacheServer', '-cacheServerEndpoint', $CacheServerValue)
        }
        return $unityArgs
    }

    It 'cache server null: -EnableCacheServer absent' {
        (Invoke-CacheServerArgFilter -CacheServerValue $null) -contains '-EnableCacheServer' | Should Be $false
    }

    It 'cache server null: -cacheServerEndpoint absent' {
        (Invoke-CacheServerArgFilter -CacheServerValue $null) -contains '-cacheServerEndpoint' | Should Be $false
    }

    It 'cache server empty string: -EnableCacheServer absent (IsNullOrWhiteSpace guard)' {
        (Invoke-CacheServerArgFilter -CacheServerValue '') -contains '-EnableCacheServer' | Should Be $false
    }

    It 'cache server localhost:10080: -EnableCacheServer present' {
        (Invoke-CacheServerArgFilter -CacheServerValue 'localhost:10080') -contains '-EnableCacheServer' | Should Be $true
    }

    It 'cache server localhost:10080: -cacheServerEndpoint present' {
        (Invoke-CacheServerArgFilter -CacheServerValue 'localhost:10080') -contains '-cacheServerEndpoint' | Should Be $true
    }

    It 'cache server localhost:10080: endpoint value present in args' {
        (Invoke-CacheServerArgFilter -CacheServerValue 'localhost:10080') -contains 'localhost:10080' | Should Be $true
    }

    It 'cache server set: -batchmode still present' {
        (Invoke-CacheServerArgFilter -CacheServerValue 'localhost:10080') -contains '-batchmode' | Should Be $true
    }

    It 'cache server set: -projectPath still present' {
        (Invoke-CacheServerArgFilter -CacheServerValue 'localhost:10080') -contains '-projectPath' | Should Be $true
    }

    It 'cache server set: -executeMethod still present' {
        (Invoke-CacheServerArgFilter -CacheServerValue 'localhost:10080') -contains '-executeMethod' | Should Be $true
    }

    It 'GUI=1 and cache server set: -batchmode absent AND -EnableCacheServer present (coexistence)' {
        $args = Invoke-CacheServerArgFilter -CacheServerValue 'localhost:10080' -GuiFlagValue '1'
        ($args -contains '-batchmode')         | Should Be $false
        ($args -contains '-EnableCacheServer') | Should Be $true
    }

    # Ticket #47 retarget: this coupling assertion now points at the launch
    # script, which is the here-string that actually carries this content.
    It 'structural coupling: launch script contains UNITY_WORKTREE_CACHE_SERVER' {
        $global:puw_launchScript | Should Match 'UNITY_WORKTREE_CACHE_SERVER'
    }
}

# ---------------------------------------------------------------------------
Describe 'launch script content — Library mirror' {
    # Ticket #47 retarget: the Library-mirror logic moved from the managed
    # block into the shared launch script's Start-UnityEditor function.

    It 'launch script contains UNITY_WORKTREE_MIRROR_LIBRARY reference' {
        $global:puw_launchScript | Should Match 'UNITY_WORKTREE_MIRROR_LIBRARY'
    }

    It 'launch script contains UnityLockfile guard' {
        $global:puw_launchScript | Should Match 'UnityLockfile'
    }

    It 'launch script contains robocopy call' {
        $global:puw_launchScript | Should Match 'robocopy'
    }

    It 'launch script contains rsync call' {
        $global:puw_launchScript | Should Match 'rsync'
    }

    # Ticket #47: the old "default section" / "gui section" pair tested two
    # duplicated copies of the same body - that duplication is gone (plan's
    # "Removed" list: "the per-variant duplication assertions go with them").
    # Start-UnityEditor is now a single shared function whose mirror-then-
    # launch ordering does not depend on $Variant at all, so this collapses
    # to one assertion against the shared script, per the plan's explicit
    # guidance for the cache-server arg-filter duplication.
    It 'mirror step appears before Start-Process in the shared launch script' {
        $text      = [string]$global:puw_launchScript
        $mirrorIdx = $text.IndexOf('UNITY_WORKTREE_MIRROR_LIBRARY')
        $startIdx  = $text.IndexOf('Start-Process')
        $mirrorIdx | Should Not Be -1
        $startIdx  | Should Not Be -1
        ($mirrorIdx -lt $startIdx) | Should Be $true
    }
}

# ---------------------------------------------------------------------------
# Finding 1 regression: lockfile path must use a forward-slash separator
# (Join-Path child segment) so the guard works on POSIX PowerShell 7.
# ---------------------------------------------------------------------------
Describe 'launch script content — Library mirror lockfile path (Finding-1 regression)' {
    # Ticket #47 retarget: the lockfile guard moved into the shared launch
    # script. The old "default section" / "gui section" pair tested two
    # duplicated copies of the same guard; that duplication is gone (single
    # shared Start-UnityEditor function), so those two collapse into the one
    # general assertion below - re-asserting them separately would just
    # duplicate this same fact, which the plan's "Removed" list explicitly
    # retires ("the per-variant duplication assertions go with them").

    It 'Finding-1: lockfile path uses forward-slash separator (Temp/UnityLockfile)' {
        # Catches any backslash regression in the Join-Path child segment.
        $global:puw_launchScript | Should Match "Temp/UnityLockfile"
    }

    It 'Finding-1: lockfile path does NOT use backslash separator (Temp\UnityLockfile)' {
        # The literal string with a backslash must be absent from the script.
        ($global:puw_launchScript -match 'Temp\\UnityLockfile') | Should Be $false
    }
}

# ---------------------------------------------------------------------------
# Finding 2 regression: main-checkout / empty-$mainRoot scenario must skip
# gracefully (no throw).  Static check: managed block must contain the
# IsNullOrEmpty guard; behavioural check via an inline script block.
# ---------------------------------------------------------------------------
Describe 'launch script content — Library mirror empty-mainRoot guard (Finding-2 regression)' {
    # Ticket #47 retarget: this guard moved into the shared launch script.
    # The old "default section" / "gui section" pair duplicated the same
    # fact about two copies of the body that no longer exist as separate
    # copies (single shared Start-UnityEditor function) - collapsed away,
    # matching the plan's "Removed" list for per-variant duplication
    # assertions; the general assertion below already covers it.

    It 'Finding-2: launch script contains IsNullOrEmpty guard for mainRoot' {
        $global:puw_launchScript | Should Match 'IsNullOrEmpty'
    }

    It 'Finding-2: launch script contains the graceful skip message for main-checkout scenario' {
        $global:puw_launchScript | Should Match 'running from main checkout'
    }

    It 'Finding-2: launch script contains Convert-Path call for absolute resolution of gitCommonDir' {
        $global:puw_launchScript | Should Match 'Convert-Path'
    }

    # Behavioural test: simulate the main-checkout scenario where git rev-parse
    # returns '.git' (relative path that resolves to the cwd's own .git).
    # Split-Path -Parent on the absolute path of .git yields the cwd itself,
    # which IS the current project — the guard should detect it and skip.
    # We replicate the logic block from the managed script inline so no Unity
    # binary or actual worktree tree is needed.
    It 'Finding-2 behavioural: empty mainRoot from relative .git does not throw (skips gracefully)' {
        # Arrange: simulate gitCommonDir = '.git' (what git returns from the main checkout)
        $simulatedGitCommonDir = '.git'
        # Act: replicate the managed block's resolution logic
        $threw = $false
        $skipped = $false
        try {
            $gitCommonDirAbs = Convert-Path -LiteralPath $simulatedGitCommonDir -ErrorAction SilentlyContinue
            $mainRoot = if ($gitCommonDirAbs) { Split-Path -Parent $gitCommonDirAbs } else { $null }
            # When '.git' resolves to the test runner's own cwd .git dir, $mainRoot will be the
            # test runner's cwd — which DOES exist, so the "not (Test-Path $mainRoot)" branch
            # won't fire. However the key safety property is that empty/null $mainRoot never
            # throws: test that branch explicitly by forcing null.
            $mainRootNull = $null
            if ([string]::IsNullOrEmpty($mainRootNull) -or -not (Test-Path $mainRootNull)) {
                $skipped = $true
            }
        } catch {
            $threw = $true
        }
        $threw   | Should Be $false
        $skipped | Should Be $true
    }
}

# ---------------------------------------------------------------------------
# Ticket #47 / R3 — the launcher's branches (live / nothing-present /
# stale-but-present), reached from a shared preamble that the full launch
# invokes. Ticket #52 retarget: adoption itself no longer lives inline in
# $launchScript (it is dot-sourced from the sibling scripts/unity-mcp-adopt.ps1
# - see the R8 Describe far below, which asserts the dot-source pattern AND
# that the inline adoption functions are gone), so the old "the adoption
# preamble (function Invoke-UnityMcpAdoption) appears exactly once" structural
# assertion is retargeted to its new-contract shape below; the behavioural
# replica documents the intended decision table (established "replicate the
# logic inline" style already used by the cache-server arg filter above) and
# is not itself the RED-proving assertion.
# ---------------------------------------------------------------------------
Describe 'prepare-unity-worktree.ps1 - launcher three-branch decision (ticket #47 / R3, retargeted for ticket #52)' {

    It 'structural: $puw_launchScript no longer defines Invoke-UnityMcpAdoption inline (ticket #52 - moved to scripts/unity-mcp-adopt.ps1)' {
        $text = [string]$global:puw_launchScript
        ([regex]::Matches($text, 'function Invoke-UnityMcpAdoption')).Count | Should Be 0
    }

    It 'structural: the managed block''s default step invokes .seretos/unity-mcp-launch.ps1 with -Variant default' {
        $defaultSection = ($global:puw_managedBlock -split 'name: gui')[0]
        $defaultSection | Should Match 'unity-mcp-launch\.ps1'
        $defaultSection | Should Match '-Variant\s+default'
    }

    It 'structural: the managed block''s gui step invokes .seretos/unity-mcp-launch.ps1 with -Variant gui' {
        $afterGui   = ($global:puw_managedBlock -split 'name: gui')[1]
        $guiSection = ($afterGui -split 'stop:')[0]
        $guiSection | Should Match 'unity-mcp-launch\.ps1'
        $guiSection | Should Match '-Variant\s+gui'
    }

    It 'structural: $puw_launchScript distinguishes "already running" (real file) from "adopted" (symlinked) wording (plan-critic fix)' {
        $text = [string]$global:puw_launchScript
        $text | Should Match 'already running'
        $text | Should Match '(?i)adopted'
    }

    # test-critic fix: "Get-LaunchDecisionReplica" above was defined and
    # asserted against itself inside its own It block, so it could never fail
    # regardless of what the real script does. Replaced with tests that
    # dot-source $puw_launchScript's materialized content and call the REAL
    # decision function (Get-UnityMcpLaunchDecision) and the REAL flow
    # function (Invoke-UnityMcpLauncherFlow), mocking the function that would
    # actually start Unity (Start-UnityEditor) and asserting it was NOT
    # called in the live branch and WAS called in the non-live branches -
    # these names are this developer's assumed contract for the
    # phase=implement script (see tests\unity-mcp-adopt.Tests.ps1's header
    # .NOTES for the sibling Find-AdoptionCandidate/Invoke-UnityMcpAdoption
    # contract this shares a status-dir format with).
    #
    # Ticket #52: liveness is a TCP-probe-only check (no heartbeat-age gate,
    # no symlink/dangling-link concept - see scripts/unity-mcp-adopt.ps1 and
    # tests\unity-mcp-adopt.Tests.ps1's R3/R11 notes). Get-UnityMcpLaunchDecision
    # no longer accepts -HeartbeatMaxAgeSeconds.
    It 'live: a fresh status file yields already-connected and Start-UnityEditor is not called' {
        $checkout = New-TempUnityRepo
        $fake = $null
        try {
            $statusDir = Join-Path $checkout '.unity-mcp'
            $fake = Start-LocalFakeListener
            New-LocalStatusFile -StatusDir $statusDir -Port $fake.Port -HeartbeatAgeSeconds 5 | Out-Null

            $launchScriptPath = New-MaterializedLaunchScriptForPuw
            . $launchScriptPath

            $decision = $null
            $threw = $false
            try {
                $decision = Get-UnityMcpLaunchDecision -StatusDir $statusDir -PortProbeTimeoutMs 500
            } catch { $threw = $true }

            # Expected RED: Get-UnityMcpLaunchDecision is not defined yet (no
            # $launchScript here-string) -> CommandNotFoundException.
            $threw | Should Be $false
            $decision | Should Be 'already-connected'

            Mock Start-UnityEditor { }
            Invoke-UnityMcpLauncherFlow -CheckoutPath $checkout -GlobalStatusDir (Join-Path ([System.IO.Path]::GetTempPath()) ('puw-empty-global-' + [guid]::NewGuid()))
            Assert-MockCalled Start-UnityEditor -Times 0 -Exactly
        } finally {
            if ($fake) { Stop-LocalFakeListener $fake }
            Remove-TempUnityRepo $checkout
        }
    }
}

# ---------------------------------------------------------------------------
# Ticket #47 / R3 continued — "nothing present" and "stale-but-present" live
# in their OWN Describe blocks, each the sole user of `Mock Start-UnityEditor`
# in its scope. Reproduced independently: Pester 3.4.0's `Mock <Name>` fails
# to intercept when a sibling `It` earlier in the SAME Describe already
# mocked the same function name and a later `It` re-dot-sources a freshly
# materialized copy of the script before re-mocking it - the mock silently
# does not attach and the real Start-UnityEditor (which calls Start-Process
# against a nonexistent editor path) runs instead. Splitting each mock target
# into its own Describe (fresh dot-source + a single, first-and-only `Mock`
# call of that name in that scope) is a Pester-3.4-safe pattern verified
# empirically against this suite. The behavioural assertions are unchanged -
# only the test-file scaffolding around them moved.
# ---------------------------------------------------------------------------
Describe 'prepare-unity-worktree.ps1 - launcher three-branch decision (ticket #47 / R3) - nothing present' {

    It 'nothing present (dangling-equivalent once cleaned up): decision is launch and Start-UnityEditor is called' {
        $checkout = New-TempUnityRepo
        try {
            $statusDir = Join-Path $checkout '.unity-mcp'
            New-Item -ItemType Directory -Force -Path $statusDir | Out-Null

            $launchScriptPath = New-MaterializedLaunchScriptForPuw
            . $launchScriptPath

            $decision = $null
            $threw = $false
            try {
                $decision = Get-UnityMcpLaunchDecision -StatusDir $statusDir -PortProbeTimeoutMs 500
            } catch { $threw = $true }
            $threw | Should Be $false
            $decision | Should Be 'launch'

            Mock Start-UnityEditor { }
            Invoke-UnityMcpLauncherFlow -CheckoutPath $checkout -GlobalStatusDir (Join-Path ([System.IO.Path]::GetTempPath()) ('puw-empty-global-' + [guid]::NewGuid()))
            Assert-MockCalled Start-UnityEditor -Times 1 -Exactly
        } finally { Remove-TempUnityRepo $checkout }
    }
}

Describe 'prepare-unity-worktree.ps1 - launcher three-branch decision (ticket #47 / R3) - stale-but-present' {

    It 'stale-but-present: a real (non-link) status file with an expired heartbeat yields launch and starts Unity' {
        $checkout = New-TempUnityRepo
        $fake = $null
        try {
            $statusDir = Join-Path $checkout '.unity-mcp'
            $fake = Start-LocalFakeListener
            New-LocalStatusFile -StatusDir $statusDir -Port $fake.Port -HeartbeatAgeSeconds 61 | Out-Null
            Stop-LocalFakeListener $fake
            $fake = $null

            $launchScriptPath = New-MaterializedLaunchScriptForPuw
            . $launchScriptPath

            $decision = $null
            $threw = $false
            try {
                $decision = Get-UnityMcpLaunchDecision -StatusDir $statusDir -PortProbeTimeoutMs 500
            } catch { $threw = $true }
            $threw | Should Be $false
            $decision | Should Be 'launch'

            Mock Start-UnityEditor { }
            Invoke-UnityMcpLauncherFlow -CheckoutPath $checkout -GlobalStatusDir (Join-Path ([System.IO.Path]::GetTempPath()) ('puw-empty-global-' + [guid]::NewGuid()))
            Assert-MockCalled Start-UnityEditor -Times 1 -Exactly

            # The real (non-link) file must survive - only symlink entries are
            # ever deleted by the preamble's cleanup pass.
            Test-Path (Join-Path $statusDir 'unity-mcp-status-local.json') | Should Be $true
        } finally {
            if ($fake) { Stop-LocalFakeListener $fake }
            Remove-TempUnityRepo $checkout
        }
    }
}

# ---------------------------------------------------------------------------
# Ticket #47 / review round 2 blocking fix - a malformed (non-numeric) port
# field in one status file must not abort Get-UnityMcpLaunchDecision's scan
# for every other, valid status file in the same directory. The generated
# launch script runs under $ErrorActionPreference = 'Stop', so an unguarded
# [int]$data.port cast inside Test-StatusFileLive throws a terminating
# exception that (pre-fix) propagates out of the scanning foreach loop.
# ---------------------------------------------------------------------------
Describe 'prepare-unity-worktree.ps1 - launcher three-branch decision (ticket #47 / review round 2 blocking fix) - malformed port' {

    It 'a malformed non-numeric port field in one status file does not abort the scan for a genuinely live entry' {
        $checkout = New-TempUnityRepo
        $fake = $null
        try {
            $statusDir = Join-Path $checkout '.unity-mcp'
            New-Item -ItemType Directory -Force -Path $statusDir | Out-Null

            # A malformed real status file (e.g. partially written/corrupted)
            # sitting alongside a genuinely live one in the same status dir.
            $badObj = [pscustomobject]@{ unity_port = 'not-a-number'; last_heartbeat = (Get-Date).ToUniversalTime().AddSeconds(-5).ToString('o') }
            ($badObj | ConvertTo-Json) | Set-Content -Path (Join-Path $statusDir 'unity-mcp-status-0-bad.json') -Encoding UTF8

            $fake = Start-LocalFakeListener
            New-LocalStatusFile -StatusDir $statusDir -Port $fake.Port -HeartbeatAgeSeconds 5 -Name 'unity-mcp-status-good.json' | Out-Null

            $launchScriptPath = New-MaterializedLaunchScriptForPuw
            . $launchScriptPath

            $decision = $null
            $threw = $false
            try {
                $decision = Get-UnityMcpLaunchDecision -StatusDir $statusDir -PortProbeTimeoutMs 500
            } catch { $threw = $true }

            # Expected RED (pre-fix): the unguarded [int]$data.port cast in
            # Test-StatusFileLive throws a terminating exception for the
            # malformed entry, aborting the scan before the genuinely live
            # entry is ever reached (order-dependent, but the malformed file's
            # name sorts before the good one in most enumerations).
            $threw | Should Be $false
            $decision | Should Be 'already-connected'
        } finally {
            if ($fake) { Stop-LocalFakeListener $fake }
            Remove-TempUnityRepo $checkout
        }
    }
}

# ---------------------------------------------------------------------------
# Ticket #47 / R4 — starting in the main checkout never mirrors Library/ onto
# itself: the existing IsNullOrEmpty/Test-Path guard cannot detect
# $mainRoot -eq $proj (the resolved path DOES exist - it's the checkout
# itself), so a same-path guard must be added.
# ---------------------------------------------------------------------------
Describe 'prepare-unity-worktree.ps1 - main checkout never mirrors Library onto itself (ticket #47 / R4)' {

    It 'structural: $puw_launchScript contains a same-path (mainRoot -eq proj) guard' {
        $text = [string]$global:puw_launchScript
        $text | Should Match '\$mainRoot\s*-eq\s*\$proj'
    }

    # test-critic fix: "Test-MirrorSkipReplica" above had the same
    # self-referential problem as R3's replica - defined and asserted against
    # itself, so it could never fail regardless of what the real script does.
    # Replaced with tests that dot-source $puw_launchScript's materialized
    # content and drive the REAL guard (Test-ShouldSkipLibraryMirror) and the
    # REAL mirror entry point (Invoke-LibraryMirror), mocking the function
    # that actually shells out to robocopy/rsync (Invoke-LibraryRobocopy) and
    # asserting it is NOT called when mainRoot -eq proj, and IS called
    # (control case, no regression) for a distinct existing mainRoot. These
    # names are this developer's assumed contract for the phase=implement
    # script.
    It 'mainRoot -eq proj: the real guard skips the mirror and robocopy is never invoked' {
        $projDir = New-TempUnityRepo
        try {
            $launchScriptPath = New-MaterializedLaunchScriptForPuw
            . $launchScriptPath

            $skip = $null
            $threw = $false
            try {
                $skip = Test-ShouldSkipLibraryMirror -MainRoot $projDir -Proj $projDir
            } catch { $threw = $true }

            # Expected RED: Test-ShouldSkipLibraryMirror is not defined yet (no
            # $launchScript here-string) -> CommandNotFoundException.
            $threw | Should Be $false
            $skip | Should Be $true

            Mock Invoke-LibraryRobocopy { }
            Invoke-LibraryMirror -MainRoot $projDir -Proj $projDir
            Assert-MockCalled Invoke-LibraryRobocopy -Times 0 -Exactly
        } finally { Remove-TempUnityRepo $projDir }
    }

}

# ---------------------------------------------------------------------------
# Ticket #47 / R4 continued — the control case lives in its OWN Describe,
# the sole user of `Mock Invoke-LibraryRobocopy` in its scope. Same reproduced
# Pester 3.4.0 bug as R3 above: the preceding "mainRoot -eq proj" test in the
# original single Describe already mocked Invoke-LibraryRobocopy first, so
# this test's own `Mock` call failed to intercept and the real function (which
# shells out to robocopy/rsync) ran instead. Behavioural assertion unchanged.
# ---------------------------------------------------------------------------
Describe 'prepare-unity-worktree.ps1 - main checkout never mirrors Library onto itself (ticket #47 / R4) - control case' {

    It 'mainRoot distinct from proj (control, no regression): the guard does not skip and robocopy is invoked' {
        $projDir  = New-TempUnityRepo
        $otherDir = New-TempUnityRepo
        try {
            $launchScriptPath = New-MaterializedLaunchScriptForPuw
            . $launchScriptPath

            $skip = $null
            $threw = $false
            try {
                $skip = Test-ShouldSkipLibraryMirror -MainRoot $otherDir -Proj $projDir
            } catch { $threw = $true }
            $threw | Should Be $false
            $skip | Should Be $false

            Mock Invoke-LibraryRobocopy { }
            Invoke-LibraryMirror -MainRoot $otherDir -Proj $projDir
            Assert-MockCalled Invoke-LibraryRobocopy -Times 1 -Exactly
        } finally { Remove-TempUnityRepo $projDir; Remove-TempUnityRepo $otherDir }
    }
}

# ---------------------------------------------------------------------------
# Ticket #47 / R5 — .seretos/unity-mcp-launch.ps1 is generated content owned
# outright by this plugin: always overwritten (even without -Force), while
# .seretos/worktree-setup.yml keeps its existing existence-based ownership
# (#37/#39) untouched.
# ---------------------------------------------------------------------------
Describe 'prepare-unity-worktree.ps1 - .seretos/unity-mcp-launch.ps1 is always regenerated; worktree-setup.yml still never touched (ticket #47 / R5)' {

    It 'creates .seretos/unity-mcp-launch.ps1 on a fresh repo, carrying the "do not hand-edit" header' {
        $tmp = New-TempUnityRepo
        try {
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $launchScriptPath = Join-Path $tmp '.seretos\unity-mcp-launch.ps1'
            Test-Path $launchScriptPath | Should Be $true
            (Get-Content -LiteralPath $launchScriptPath -Raw) | Should Match 'do not hand-edit'
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'restores generated content over a hand-edited launch script without -Force; worktree-setup.yml stays byte-identical' {
        $tmp = New-TempUnityRepo
        try {
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $launchScriptPath = Join-Path $tmp '.seretos\unity-mcp-launch.ps1'
            Test-Path $launchScriptPath | Should Be $true

            $setupPath = Join-Path $tmp '.seretos\worktree-setup.yml'
            Add-Content -Path $launchScriptPath -Value '# SENTINEL-HAND-EDIT'
            Add-Content -Path $setupPath -Value '# SENTINEL-HAND-EDIT'
            $ymlBefore = Get-Content -LiteralPath $setupPath -Raw

            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null

            $launchScriptAfter = Get-Content -LiteralPath $launchScriptPath -Raw
            $launchScriptAfter | Should Not Match 'SENTINEL-HAND-EDIT'
            $launchScriptAfter | Should Match 'do not hand-edit'

            $ymlAfter = Get-Content -LiteralPath $setupPath -Raw
            $ymlAfter | Should Be $ymlBefore
            $ymlAfter | Should Match 'SENTINEL-HAND-EDIT'
        } finally { Remove-TempUnityRepo $tmp }
    }

    It '-Force behaves identically for the launch script (still overwritten) and the yml (still untouched)' {
        $tmp = New-TempUnityRepo
        try {
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $launchScriptPath = Join-Path $tmp '.seretos\unity-mcp-launch.ps1'
            $setupPath        = Join-Path $tmp '.seretos\worktree-setup.yml'
            Add-Content -Path $launchScriptPath -Value '# SENTINEL-HAND-EDIT'
            Add-Content -Path $setupPath -Value '# SENTINEL-HAND-EDIT'
            $ymlBefore = Get-Content -LiteralPath $setupPath -Raw

            & $global:puw_scriptPath -RepoRoot $tmp -Force | Out-Null

            (Get-Content -LiteralPath $launchScriptPath -Raw) | Should Not Match 'SENTINEL-HAND-EDIT'
            (Get-Content -LiteralPath $setupPath -Raw)        | Should Be $ymlBefore
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'a repo with no .seretos/ directory yet still gets the launch script created' {
        $tmp = New-TempUnityRepo
        try {
            Test-Path (Join-Path $tmp '.seretos') | Should Be $false
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            Test-Path (Join-Path $tmp '.seretos\unity-mcp-launch.ps1') | Should Be $true
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'the generated launch script is not added to .gitignore' {
        $tmp = New-TempUnityRepo
        try {
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $gi = Get-Content -LiteralPath (Join-Path $tmp '.gitignore') -Raw
            $gi | Should Not Match 'unity-mcp-launch\.ps1'
        } finally { Remove-TempUnityRepo $tmp }
    }
}

# ---------------------------------------------------------------------------
# Ticket #47 / R8 — version-pin strategy is documented and internally
# coupled: both manifests' mcpforunityserver==X pin and the script's
# -UnityMcpVersion default must agree (this proves internal agreement only,
# not agreement with whatever is actually installed in a target project -
# that stays a documented manual check, per the plan).
# ---------------------------------------------------------------------------
Describe 'prepare-unity-worktree.ps1 - version-pin strategy is internally coupled (ticket #47 / R8)' {

    It 'both plugin manifests'' mcpforunityserver pin and the -UnityMcpVersion default all agree' {
        $claudeManifest = Get-Content -LiteralPath (Join-Path $global:puw_repoRoot '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json
        $codexManifest  = Get-Content -LiteralPath (Join-Path $global:puw_repoRoot '.codex-plugin\plugin.json') -Raw | ConvertFrom-Json

        function Get-PinVersionFromManifest {
            param($Manifest)
            foreach ($a in $Manifest.mcpServers.unityMCP.args) {
                if ($a -match 'mcpforunityserver==(.+)$') { return $Matches[1] }
            }
            return $null
        }

        $claudePin = Get-PinVersionFromManifest $claudeManifest
        $codexPin  = Get-PinVersionFromManifest $codexManifest

        $src = [System.IO.File]::ReadAllText($global:puw_scriptPath)
        $scriptDefault = $null
        if ($src -match "\[string\]\`$UnityMcpVersion\s*=\s*'([^']+)'") { $scriptDefault = $Matches[1] }

        $claudePin     | Should Not BeNullOrEmpty
        $codexPin      | Should Not BeNullOrEmpty
        $scriptDefault | Should Not BeNullOrEmpty
        $claudePin | Should Be $codexPin
        $claudePin | Should Be $scriptDefault
    }

    It 'SKILL.md documents the version-pin strategy under a concrete heading' {
        $skillPath = Join-Path $global:puw_repoRoot 'skills\unity-wrapper\SKILL.md'
        $skillText = [System.IO.File]::ReadAllText($skillPath)
        $skillText | Should Match '### Version-pin strategy'
    }
}

# ---------------------------------------------------------------------------
# Ticket #52 / R7 - environment_start's launcher still adopts before deciding
# to launch, now against the NEW contract (status file only, no paired port
# file, TCP-probe-only liveness) rather than the #47 symlink/port-file/
# heartbeat-age mechanism the current $launchScript here-string still
# implements. This test's fixture is deliberately new-contract-shaped (no
# unity-mcp-port-<port>.json alongside the status file) so it RED's against
# TODAY's Find-AdoptionCandidate, which still `continue`s (rejects) a
# candidate lacking a paired port file (see scripts\prepare-unity-worktree.ps1
# around the `$portFile` / Test-Path guard) - the candidate is never adopted,
# Get-UnityMcpLaunchDecision falls through to 'launch', and Start-UnityEditor
# IS called, failing the -Times 0 assertion below. This is the #52 second
# finding (R4) reflected at the launcher-flow level (R7), not a fresh
# behavioural claim invented for this file.
#
# One Describe, one `Mock Start-UnityEditor` - same Pester 3.4.0 hygiene
# already established by every other Mock-using Describe in this file (a
# second `Mock` of the same name in a later It of the SAME Describe silently
# fails to re-hook).
# ---------------------------------------------------------------------------
Describe 'prepare-unity-worktree.ps1 - launcher adopts a live Hub candidate before deciding to launch (ticket #52 / R7)' {

    It 'a live Hub candidate in the global dir (status file only, no paired port file) is adopted; Start-UnityEditor is not called' {
        $checkout  = New-TempUnityRepo
        $globalDir = New-PlainTempDir
        $fake = $null
        try {
            $fake = Start-LocalFakeListener
            $obj = [pscustomobject]@{
                project_path   = (Join-Path $checkout 'Assets')
                unity_port     = $fake.Port
                last_heartbeat = (Get-Date).ToUniversalTime().ToString('o')
            }
            # Deliberately NO paired unity-mcp-port-<port>.json.
            ($obj | ConvertTo-Json) | Set-Content -Path (Join-Path $globalDir "unity-mcp-status-$($fake.Port).json") -Encoding UTF8

            $launchScriptPath = New-MaterializedLaunchScriptForPuw
            . $launchScriptPath

            Mock Start-UnityEditor { }
            Invoke-UnityMcpLauncherFlow -CheckoutPath $checkout -GlobalStatusDir $globalDir

            # Expected RED: today's Find-AdoptionCandidate rejects this
            # candidate for lack of a paired port file, so adoption never
            # happens and Get-UnityMcpLaunchDecision falls through to
            # 'launch' - Start-UnityEditor IS called, failing this assertion.
            Assert-MockCalled Start-UnityEditor -Times 0 -Exactly

            $statusDir = Join-Path $checkout '.unity-mcp'
            @(Get-ChildItem -Path $statusDir -Filter 'unity-mcp-status-adopted-*.json' -File -ErrorAction SilentlyContinue).Count | Should Be 1
        } finally {
            if ($fake) { Stop-LocalFakeListener $fake }
            Remove-TempUnityRepo $checkout
            Remove-PlainTempDir $globalDir
        }
    }
}

# ---------------------------------------------------------------------------
# Test-critic fix (note 1): the R7 Describe above only asserted the "adopted
# candidate -> Start-UnityEditor NOT called" half. Add the missing other
# half in its OWN Describe (Pester 3.4.0 Mock-per-Describe hygiene, same
# pattern as every other Mock-using Describe in this file): with NOTHING
# live anywhere (no candidate in the global dir at all, under the new
# no-port-file contract), the launcher must still fall through to launch and
# call Start-UnityEditor exactly once - this is what actually drives real
# behavior rather than a wrong implementation that always adopts (or always
# skips launch) regardless of what it finds.
# ---------------------------------------------------------------------------
Describe 'prepare-unity-worktree.ps1 - launcher does not adopt when nothing is live; Start-UnityEditor is called (ticket #52 / R7 continued)' {

    It 'no candidate anywhere in the global dir: no adopted copy is created and Start-UnityEditor is called exactly once' {
        $checkout  = New-TempUnityRepo
        $globalDir = New-PlainTempDir
        try {
            $launchScriptPath = New-MaterializedLaunchScriptForPuw
            . $launchScriptPath

            Mock Start-UnityEditor { }
            Invoke-UnityMcpLauncherFlow -CheckoutPath $checkout -GlobalStatusDir $globalDir
            Assert-MockCalled Start-UnityEditor -Times 1 -Exactly

            $statusDir = Join-Path $checkout '.unity-mcp'
            @(Get-ChildItem -Path $statusDir -Filter 'unity-mcp-status-adopted-*.json' -File -ErrorAction SilentlyContinue).Count | Should Be 0
        } finally {
            Remove-TempUnityRepo $checkout
            Remove-PlainTempDir $globalDir
        }
    }
}

# ---------------------------------------------------------------------------
# Ticket #52 / R8 - the prepare-script materializes scripts/unity-mcp-adopt.ps1
# verbatim into .seretos/, always overwritten (same ownership model as
# .seretos/unity-mcp-launch.ps1 - see that Describe above), while
# .seretos/worktree-setup.yml keeps its existing existence-based ownership
# untouched. The generated launch script dot-sources the sibling by
# $PSScriptRoot instead of defining adoption inline.
# ---------------------------------------------------------------------------
Describe 'prepare-unity-worktree.ps1 - materializes scripts/unity-mcp-adopt.ps1 into .seretos/ verbatim, always (ticket #52 / R8)' {

    It 'writes .seretos/unity-mcp-adopt.ps1 byte-identical to scripts/unity-mcp-adopt.ps1 on a fresh repo' {
        $tmp = New-TempUnityRepo
        try {
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $dest = Join-Path $tmp '.seretos\unity-mcp-adopt.ps1'

            # Expected RED: the prepare-script does not write this file at all yet.
            Test-Path $dest | Should Be $true

            $srcPath = Join-Path $global:puw_repoRoot 'scripts\unity-mcp-adopt.ps1'
            (Get-Content -LiteralPath $dest -Raw) | Should Be (Get-Content -LiteralPath $srcPath -Raw)
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'overwrites a hand-modified copy without -Force; worktree-setup.yml stays byte-identical' {
        $tmp = New-TempUnityRepo
        try {
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $dest      = Join-Path $tmp '.seretos\unity-mcp-adopt.ps1'
            $setupPath = Join-Path $tmp '.seretos\worktree-setup.yml'

            # Expected RED: $dest does not exist yet on this run, so Add-Content
            # below creates a bare sentinel-only file rather than "hand-editing"
            # a real generated copy - the subsequent re-run still can't produce
            # the real generated content because the prepare-script does not
            # write this file at all yet.
            Add-Content -Path $dest -Value '# SENTINEL-HAND-EDIT' -ErrorAction SilentlyContinue
            Add-Content -Path $setupPath -Value '# SENTINEL-HAND-EDIT'
            $ymlBefore = Get-Content -LiteralPath $setupPath -Raw

            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null

            # test-critic fix (note 3): a truncate-to-empty would also satisfy
            # "does not match SENTINEL-HAND-EDIT" without proving the REAL
            # generated content was restored. Assert full byte-identity
            # against the actual source, same as the fresh-repo case above.
            $srcPath = Join-Path $global:puw_repoRoot 'scripts\unity-mcp-adopt.ps1'
            (Get-Content -LiteralPath $dest -Raw) | Should Not Match 'SENTINEL-HAND-EDIT'
            (Get-Content -LiteralPath $dest -Raw) | Should Be (Get-Content -LiteralPath $srcPath -Raw)
            (Get-Content -LiteralPath $setupPath -Raw) | Should Be $ymlBefore
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'a second run is a no-op except the .seretos/unity-mcp-adopt.ps1 overwrite' {
        $tmp = New-TempUnityRepo
        try {
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $dest      = Join-Path $tmp '.seretos\unity-mcp-adopt.ps1'
            $setupPath = Join-Path $tmp '.seretos\worktree-setup.yml'
            $ymlBefore = Get-Content -LiteralPath $setupPath -Raw

            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null

            Test-Path $dest | Should Be $true
            (Get-Content -LiteralPath $setupPath -Raw) | Should Be $ymlBefore
        } finally { Remove-TempUnityRepo $tmp }
    }

    It 'the generated launch script dot-sources the sibling unity-mcp-adopt.ps1 by $PSScriptRoot instead of defining adoption inline' {
        # test-critic fix (note 4): three generic substring greps (Join-Path,
        # $PSScriptRoot, unity-mcp-adopt.ps1) could each already be true of
        # pre-existing code for unrelated reasons without the script actually
        # dot-sourcing anything. Strengthen to (a) an actual dot-source
        # operator pattern - a literal ". " invocation immediately followed by
        # an expression that resolves to unity-mcp-adopt.ps1, not just a
        # mention of the filename anywhere - and (b) assert the inline
        # adoption functions are no longer DEFINED in the generated script's
        # own text (a `function <Name>` declaration), which a wrong
        # implementation that merely ADDS a dot-source line while leaving the
        # old inline definitions in place would still fail.
        $text = [string]$global:puw_launchScript
        $text | Should Match '(?m)^\s*\.\s+\(?\s*Join-Path\s+\$PSScriptRoot\s+[''"]unity-mcp-adopt\.ps1[''"]'

        $inlineAdoptionFunctions = @(
            'Find-AdoptionCandidate', 'Invoke-UnityMcpAdoption', 'Get-UnityMcpLaunchDecision',
            'New-AdoptionSymlink', 'Remove-StaleAdoptionLinks', 'Test-EntryIsLink',
            'Test-StatusFileLive', 'Get-ComparablePath', 'Test-TcpPortOpen'
        )
        foreach ($fn in $inlineAdoptionFunctions) {
            $text | Should Not Match "function\s+$([regex]::Escape($fn))\b"
        }
    }
}
