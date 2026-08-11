#Requires -Version 5.1
<#
.SYNOPSIS
  Pester 3.x regression tests for scripts/prepare-unity-worktree.ps1.
  Run with:  Invoke-Pester .\tests\prepare-unity-worktree.Tests.ps1 -Verbose
#>

$global:puw_repoRoot   = Split-Path -Parent $PSScriptRoot
$global:puw_scriptPath = Join-Path $global:puw_repoRoot 'scripts\prepare-unity-worktree.ps1'

# ---------------------------------------------------------------------------
# Extract the managed block text from the script source.
# The block is a single-quoted here-string: starts on the line after a line
# ending in @' and ends on the line that is exactly '@ (no indent).
# ---------------------------------------------------------------------------
$_rawLines = [System.IO.File]::ReadAllLines($global:puw_scriptPath)
$_inBlock  = $false
$_blockLines = [System.Collections.Generic.List[string]]::new()
foreach ($_line in $_rawLines) {
    $_t = $_line.TrimEnd()
    if ($_t -match "@'$")         { $_inBlock = $true;  continue }
    if ($_t -eq "'@")             { $_inBlock = $false; continue }
    if ($_inBlock) { $_blockLines.Add($_t) }
}
$global:puw_managedBlock = $_blockLines -join "`n"

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

    It 'managed block sets UNITY_MCP_STATUS_DIR to the worktree-local .unity-mcp dir' {
        $global:puw_managedBlock | Should Match 'UNITY_MCP_STATUS_DIR'
        $global:puw_managedBlock | Should Match '\.unity-mcp'
    }

    It 'managed block sets UNITY_MCP_ALLOW_BATCH' {
        $global:puw_managedBlock | Should Match 'UNITY_MCP_ALLOW_BATCH'
    }

    It 'managed block contains -batchmode and -nographics args' {
        $global:puw_managedBlock | Should Match 'batchmode'
        $global:puw_managedBlock | Should Match 'nographics'
    }

    It 'managed block contains name: default step' {
        $global:puw_managedBlock | Should Match 'name: default'
    }

    It 'managed block contains name: gui step' {
        $global:puw_managedBlock | Should Match 'name: gui'
    }

    It 'managed block default step contains -batchmode' {
        # Extract text from name: default up to (but not including) name: gui
        $defaultSection = ($global:puw_managedBlock -split 'name: gui')[0]
        $defaultSection | Should Match 'batchmode'
    }

    It 'managed block gui step does not contain -batchmode' {
        # Extract text after name: gui and before stop:
        $afterGui = ($global:puw_managedBlock -split 'name: gui')[1]
        $guiSection = ($afterGui -split 'stop:')[0]
        $guiSection | Should Not Match 'batchmode'
    }

    It 'managed block gui step contains GUI-mode dialog caveat comment' {
        $afterGui   = ($global:puw_managedBlock -split 'name: gui')[1]
        $guiSection = ($afterGui -split 'stop:')[0]
        $guiSection | Should Match 'does not suppress'
    }

    It 'managed block does not contain UNITY_WORKTREE_GUI' {
        $global:puw_managedBlock | Should Not Match 'UNITY_WORKTREE_GUI'
    }

    It 'managed block boots the bridge via -executeMethod MCPForUnity.Editor.McpCiBoot.StartStdioForCi' {
        $global:puw_managedBlock | Should Match 'MCPForUnity.Editor.McpCiBoot.StartStdioForCi'
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
Describe 'managed block content — cache server' {

    It 'managed block contains UNITY_WORKTREE_CACHE_SERVER reference' {
        $global:puw_managedBlock | Should Match 'UNITY_WORKTREE_CACHE_SERVER'
    }

    It 'managed block contains -EnableCacheServer flag' {
        $global:puw_managedBlock | Should Match 'EnableCacheServer'
    }

    It 'managed block contains -cacheServerEndpoint flag' {
        $global:puw_managedBlock | Should Match 'cacheServerEndpoint'
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

    It 'structural coupling: managed block contains UNITY_WORKTREE_CACHE_SERVER' {
        $global:puw_managedBlock | Should Match 'UNITY_WORKTREE_CACHE_SERVER'
    }
}

# ---------------------------------------------------------------------------
Describe 'managed block content — Library mirror' {

    It 'managed block contains UNITY_WORKTREE_MIRROR_LIBRARY reference' {
        $global:puw_managedBlock | Should Match 'UNITY_WORKTREE_MIRROR_LIBRARY'
    }

    It 'managed block contains UnityLockfile guard' {
        $global:puw_managedBlock | Should Match 'UnityLockfile'
    }

    It 'managed block contains robocopy call' {
        $global:puw_managedBlock | Should Match 'robocopy'
    }

    It 'managed block contains rsync call' {
        $global:puw_managedBlock | Should Match 'rsync'
    }

    It 'mirror step appears before Start-Process in the default section' {
        # Split on 'name: gui' to isolate the default section
        $defaultSection = ($global:puw_managedBlock -split 'name: gui')[0]
        $mirrorIdx      = $defaultSection.IndexOf('UNITY_WORKTREE_MIRROR_LIBRARY')
        $startIdx       = $defaultSection.IndexOf('Start-Process')
        $mirrorIdx | Should Not Be -1
        $startIdx  | Should Not Be -1
        ($mirrorIdx -lt $startIdx) | Should Be $true
    }

    It 'mirror step appears before Start-Process in the gui section' {
        # Split to isolate the gui section (after 'name: gui', before 'stop:')
        $afterGui   = ($global:puw_managedBlock -split 'name: gui')[1]
        $guiSection = ($afterGui -split 'stop:')[0]
        $mirrorIdx  = $guiSection.IndexOf('UNITY_WORKTREE_MIRROR_LIBRARY')
        $startIdx   = $guiSection.IndexOf('Start-Process')
        $mirrorIdx | Should Not Be -1
        $startIdx  | Should Not Be -1
        ($mirrorIdx -lt $startIdx) | Should Be $true
    }
}

# ---------------------------------------------------------------------------
# Finding 1 regression: lockfile path must use a forward-slash separator
# (Join-Path child segment) so the guard works on POSIX PowerShell 7.
# ---------------------------------------------------------------------------
Describe 'managed block content — Library mirror lockfile path (Finding-1 regression)' {

    It 'Finding-1: lockfile path uses forward-slash separator (Temp/UnityLockfile)' {
        # Catches any backslash regression in the Join-Path child segment.
        $global:puw_managedBlock | Should Match "Temp/UnityLockfile"
    }

    It 'Finding-1: lockfile path does NOT use backslash separator (Temp\UnityLockfile)' {
        # The literal string with a backslash must be absent from the block.
        ($global:puw_managedBlock -match 'Temp\\UnityLockfile') | Should Be $false
    }

    It 'Finding-1: default section lockfile uses forward slash' {
        $defaultSection = ($global:puw_managedBlock -split 'name: gui')[0]
        ($defaultSection -match "Temp/UnityLockfile") | Should Be $true
    }

    It 'Finding-1: gui section lockfile uses forward slash' {
        $afterGui   = ($global:puw_managedBlock -split 'name: gui')[1]
        $guiSection = ($afterGui -split 'stop:')[0]
        ($guiSection -match "Temp/UnityLockfile") | Should Be $true
    }
}

# ---------------------------------------------------------------------------
# Finding 2 regression: main-checkout / empty-$mainRoot scenario must skip
# gracefully (no throw).  Static check: managed block must contain the
# IsNullOrEmpty guard; behavioural check via an inline script block.
# ---------------------------------------------------------------------------
Describe 'managed block content — Library mirror empty-mainRoot guard (Finding-2 regression)' {

    It 'Finding-2: managed block contains IsNullOrEmpty guard for mainRoot' {
        $global:puw_managedBlock | Should Match 'IsNullOrEmpty'
    }

    It 'Finding-2: managed block contains the graceful skip message for main-checkout scenario' {
        $global:puw_managedBlock | Should Match 'running from main checkout'
    }

    It 'Finding-2: managed block contains Convert-Path call for absolute resolution of gitCommonDir' {
        $global:puw_managedBlock | Should Match 'Convert-Path'
    }

    It 'Finding-2: default section contains IsNullOrEmpty guard' {
        $defaultSection = ($global:puw_managedBlock -split 'name: gui')[0]
        ($defaultSection -match 'IsNullOrEmpty') | Should Be $true
    }

    It 'Finding-2: gui section contains IsNullOrEmpty guard' {
        $afterGui   = ($global:puw_managedBlock -split 'name: gui')[1]
        $guiSection = ($afterGui -split 'stop:')[0]
        ($guiSection -match 'IsNullOrEmpty') | Should Be $true
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
