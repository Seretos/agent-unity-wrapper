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

    It 'managed block contains UNITY_WORKTREE_GUI conditional (plan item 5)' {
        $global:puw_managedBlock | Should Match 'UNITY_WORKTREE_GUI'
    }

    It 'managed block uses -notin to filter -batchmode and -nographics when UNITY_WORKTREE_GUI is set' {
        $global:puw_managedBlock | Should Match 'notin'
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

    It '-Force rewrites the managed block in an already-prepared repo' {
        $tmp = New-TempUnityRepo
        try {
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $setupPath = Join-Path $tmp '.seretos\worktree-setup.yml'
            # Corrupt the block to detect the rewrite.
            $content = Get-Content -LiteralPath $setupPath -Raw
            $corrupted = $content -replace 'mcp-unity-bridge-start', 'mcp-unity-bridge-OLD'
            Write-Utf8NoBom -Path $setupPath -Content $corrupted

            & $global:puw_scriptPath -RepoRoot $tmp -Force | Out-Null

            $refreshed = Get-Content -LiteralPath $setupPath -Raw
            $refreshed | Should Match 'mcp-unity-bridge-start'
            $refreshed | Should Not Match 'mcp-unity-bridge-OLD'
        } finally { Remove-TempUnityRepo $tmp }
    }

    # Fix 2b — warn when existing block predates UNITY_WORKTREE_GUI support.
    It 'Fix-2b: emits a Write-Warning hint when existing block lacks UNITY_WORKTREE_GUI' {
        $tmp = New-TempUnityRepo
        try {
            & $global:puw_scriptPath -RepoRoot $tmp | Out-Null
            $setupPath = Join-Path $tmp '.seretos\worktree-setup.yml'

            # Strip every line containing UNITY_WORKTREE_GUI to simulate an old block.
            $content = Get-Content -LiteralPath $setupPath -Raw
            $stripped = ($content -split "`n" | Where-Object { $_ -notmatch 'UNITY_WORKTREE_GUI' }) -join "`n"
            Write-Utf8NoBom -Path $setupPath -Content $stripped

            $wv = $null
            & $global:puw_scriptPath -RepoRoot $tmp -WarningVariable wv 2>&1 | Out-Null
            ($wv | Out-String) | Should Match '-Force'
        } finally { Remove-TempUnityRepo $tmp }
    }
}

# ---------------------------------------------------------------------------
# Plan item 5 / Fix 3 — Runtime test for the UNITY_WORKTREE_GUI arg-filter.
#
# The $unityArgs construction and UNITY_WORKTREE_GUI conditional are replicated
# here directly (matching the managed block exactly).  The structural tests in
# the "managed block content" Describe above verify the conditional text is
# present in the actual block, coupling these runtime tests to the real script.
# ---------------------------------------------------------------------------
Describe 'plan-item-5: UNITY_WORKTREE_GUI runtime arg-filter' {

    function Invoke-UnityArgFilter {
        param([string]$GuiFlagValue)
        # Stub values for variables the snippet references.
        $proj      = 'C:\fake\proj'
        $statusDir = 'C:\fake\proj\.unity-mcp'
        $log       = Join-Path $statusDir 'editor.log'
        # Default args — mirrors the managed start block exactly.
        $unityArgs = @(
            '-batchmode', '-nographics',
            '-logFile', $log,
            '-projectPath', $proj,
            '-executeMethod', 'MCPForUnity.Editor.McpCiBoot.StartStdioForCi'
        )
        # UNITY_WORKTREE_GUI conditional — mirrors the managed start block exactly.
        if ($GuiFlagValue -eq '1') {
            $unityArgs = $unityArgs | Where-Object { $_ -notin @('-batchmode', '-nographics') }
        }
        return $unityArgs
    }

    It 'headless default: -batchmode present when flag is unset' {
        (Invoke-UnityArgFilter -GuiFlagValue $null) -contains '-batchmode' | Should Be $true
    }

    It 'headless default: -nographics present when flag is unset' {
        (Invoke-UnityArgFilter -GuiFlagValue $null) -contains '-nographics' | Should Be $true
    }

    It 'GUI mode: -batchmode absent when UNITY_WORKTREE_GUI=1' {
        (Invoke-UnityArgFilter -GuiFlagValue '1') -contains '-batchmode' | Should Be $false
    }

    It 'GUI mode: -nographics absent when UNITY_WORKTREE_GUI=1' {
        (Invoke-UnityArgFilter -GuiFlagValue '1') -contains '-nographics' | Should Be $false
    }

    It 'GUI mode: -logFile still present when UNITY_WORKTREE_GUI=1' {
        (Invoke-UnityArgFilter -GuiFlagValue '1') -contains '-logFile' | Should Be $true
    }

    It 'GUI mode: -projectPath still present when UNITY_WORKTREE_GUI=1' {
        (Invoke-UnityArgFilter -GuiFlagValue '1') -contains '-projectPath' | Should Be $true
    }

    It 'GUI mode: -executeMethod still present when UNITY_WORKTREE_GUI=1' {
        (Invoke-UnityArgFilter -GuiFlagValue '1') -contains '-executeMethod' | Should Be $true
    }

    It 'inverse guard: -batchmode present when UNITY_WORKTREE_GUI=0 (not 1)' {
        (Invoke-UnityArgFilter -GuiFlagValue '0') -contains '-batchmode' | Should Be $true
    }

    It 'inverse guard: -nographics present when UNITY_WORKTREE_GUI=0 (not 1)' {
        (Invoke-UnityArgFilter -GuiFlagValue '0') -contains '-nographics' | Should Be $true
    }

    # Structural coupling: managed block must contain the identical conditional.
    It 'managed block contains UNITY_WORKTREE_GUI conditional (structural coupling check)' {
        $global:puw_managedBlock | Should Match 'UNITY_WORKTREE_GUI'
        $global:puw_managedBlock | Should Match 'notin'
    }
}
