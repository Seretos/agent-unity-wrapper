#Requires -Version 5.1
<#
.SYNOPSIS
  Pester 3.x regression tests for skills/unity-wrapper/SKILL.md (ticket #31 -
  Pitfall 1 wording). Read in isolation, the old Pitfall 1 text implied a
  failed Unity tool call permanently poisons the session ("every call will
  error"). In fact instance discovery happens fresh on every call by
  rescanning UNITY_MCP_STATUS_DIR - only the status directory is fixed at
  server startup, never a bound Unity instance. These tests guard the
  corrected wording: a failed call is recoverable in-session (start Unity,
  retry), while Pitfall 5's raw-Unity.exe case remains the one genuinely
  non-retryable variant.
  Run with:  Invoke-Pester .\tests\skill-md.Tests.ps1 -Verbose
#>

$global:skillmd_repoRoot = Split-Path -Parent $PSScriptRoot
$global:skillmd_path     = Join-Path $global:skillmd_repoRoot 'skills\unity-wrapper\SKILL.md'
$global:skillmd_text     = [System.IO.File]::ReadAllText($global:skillmd_path)
$global:skillmd_errorString = 'No Unity Editor instances found. Please ensure Unity is running with MCP for Unity bridge.'

# Extract a numbered pitfall region from within "## Pitfalls": from
# "\n<Number>. **" up to (not including) "\n<NextNumber>. **". Scoped to
# start searching only after the "## Pitfalls" heading so it cannot match an
# unrelated numbered list earlier in the file (e.g. the architecture section's
# "1. **Python MCP server**"). Returns '' if the start marker is absent.
function Get-PitfallRegion {
    param([string]$Text, [int]$Number, [int]$NextNumber)
    $sectionStart = $Text.IndexOf('## Pitfalls')
    if ($sectionStart -eq -1) { return '' }
    $section = $Text.Substring($sectionStart)
    $startMarker = "`n$Number. **"
    $endMarker   = "`n$NextNumber. **"
    $sIdx = $section.IndexOf($startMarker)
    if ($sIdx -eq -1) { return '' }
    $eIdx = $section.IndexOf($endMarker, $sIdx)
    if ($eIdx -eq -1) { return $section.Substring($sIdx) }
    return $section.Substring($sIdx, $eIdx - $sIdx)
}

Describe 'SKILL.md -- recovery from a failed Unity call (ticket #31)' {

    It 'names the discovery-failure error string verbatim' {
        $global:skillmd_text.Contains($global:skillmd_errorString) | Should Be $true
    }

    It 'Pitfall 1 mentions worktree_start as the recovery step' {
        $pitfall1 = Get-PitfallRegion -Text $global:skillmd_text -Number 1 -NextNumber 2
        $pitfall1 | Should Match 'worktree_start'
    }

    It 'Pitfall 1 mentions retrying the same call' {
        $pitfall1 = Get-PitfallRegion -Text $global:skillmd_text -Number 1 -NextNumber 2
        $pitfall1 | Should Match '(?i)retry'
    }

    It 'Pitfall 1 mentions refresh_unity recovering a dropped Unity' {
        $pitfall1 = Get-PitfallRegion -Text $global:skillmd_text -Number 1 -NextNumber 2
        $pitfall1 | Should Match 'refresh_unity'
    }

    It 'the phrase "every call will error" no longer appears anywhere in the file' {
        $global:skillmd_text.Contains('every call will error') | Should Be $false
    }
}

Describe 'SKILL.md -- discovery is per-call, and tool presence != reachability (ticket #31)' {
    $pitfall1 = Get-PitfallRegion -Text $global:skillmd_text -Number 1 -NextNumber 2

    It 'documents that instance discovery is per-call, not resolved at server startup' {
        $pitfall1 | Should Match 'every call'
        $pitfall1 | Should Match 'UNITY_MCP_STATUS_DIR'
    }

    It 'states that only the status directory is fixed, never a bound instance' {
        $pitfall1 | Should Match '(?i)only the status'
    }

    It 'distinguishes a static tool list from call-time reachability' {
        $pitfall1 | Should Match '(?i)static'
    }

    It 'cross-references the Status-dir isolation contract by name' {
        $pitfall1 | Should Match 'Status-dir isolation contract'
    }

    It 'the "Status-dir isolation contract" heading still exists (guards a dangling reference)' {
        $global:skillmd_text | Should Match '### Status-dir isolation contract'
    }
}

Describe 'SKILL.md -- Pitfall 5 is the non-retryable variant (ticket #31)' {
    $pitfall5 = Get-PitfallRegion -Text $global:skillmd_text -Number 5 -NextNumber 6

    It 'mentions the discovery-failure error string' {
        $pitfall5.Contains($global:skillmd_errorString) | Should Be $true
    }

    It 'states that retrying will not help' {
        $pitfall5 | Should Match '(?i)retry(ing)? (will )?keep(s)? failing'
    }

    It 'mentions the global ~/.unity-mcp status dir' {
        $pitfall5.Contains('~/.unity-mcp') | Should Be $true
    }

    It 'no longer says the calls fail silently' {
        $pitfall5 | Should Not Match 'fail silently'
    }

    It 'still closes with the "Always start via worktree_start" instruction' {
        $pitfall5 | Should Match '(?s)Always start\s+via'
    }
}

Describe 'SKILL.md -- structural guards (ticket #31)' {

    It 'file still starts with frontmatter delimiter ---' {
        $global:skillmd_text.TrimStart().StartsWith('---') | Should Be $true
    }

    It 'frontmatter contains name: unity-wrapper' {
        $global:skillmd_text | Should Match 'name: unity-wrapper'
    }

    It 'frontmatter contains a description: line' {
        $global:skillmd_text | Should Match 'description:'
    }

    It 'SKILL.md contains no CR bytes' {
        $bytes = [System.IO.File]::ReadAllBytes($global:skillmd_path)
        ($bytes -contains 13) | Should Be $false
    }
}
