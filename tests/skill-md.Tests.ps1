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

# --- ticket #33: description discoverability + tool-inventory accuracy ------

# Returns the single "description:" line's value from the leading frontmatter
# block (text between the opening --- and the next \n---), with the key
# stripped. Returns '' if no such block/line is found.
function Get-FrontmatterDescription {
    param([string]$Text)
    $start = $Text.IndexOf('---')
    if ($start -eq -1) { return '' }
    $end = $Text.IndexOf("`n---", $start + 3)
    if ($end -eq -1) { return '' }
    $frontmatter = $Text.Substring($start, $end - $start)
    foreach ($line in ($frontmatter -split "`n")) {
        if ($line -match '^description:\s*(.*)$') {
            return $Matches[1]
        }
    }
    return ''
}

# Returns the substring from a given "## Heading" (inclusive) up to (not
# including) the next top-level "## " heading. Returns '' if the heading is
# absent; returns the rest of the file if there is no following "## ".
function Get-Section {
    param([string]$Text, [string]$Heading)
    $sIdx = $Text.IndexOf($Heading)
    if ($sIdx -eq -1) { return '' }
    $eIdx = $Text.IndexOf("`n## ", $sIdx + $Heading.Length)
    if ($eIdx -eq -1) { return $Text.Substring($sIdx) }
    return $Text.Substring($sIdx, $eIdx - $sIdx)
}

Describe 'SKILL.md -- frontmatter description covers the whole skill (ticket #33)' {
    $description = Get-FrontmatterDescription -Text $global:skillmd_text

    It 'the description mentions Play mode' {
        $description | Should Match '(?i)play mode'
    }

    It 'the description mentions run_tests and Test Runner' {
        $description | Should Match 'run_tests'
        $description | Should Match 'Test Runner'
    }

    It 'the description mentions the console and compilation errors' {
        $description | Should Match 'console'
        $description | Should Match 'compil'
    }

    It 'the description mentions screenshots' {
        $description | Should Match 'screenshot'
    }

    It 'the description mentions worktree_start' {
        $description | Should Match 'worktree_start'
    }

    It 'the description mentions headless and GUI variants' {
        $description | Should Match 'headless'
        $description | Should Match '(?i)gui'
    }

    It 'the description mentions cold-start expectations' {
        $description | Should Match 'cold-start'
    }

    It 'the description mentions the stale UnityLockfile recovery case' {
        $description | Should Match 'UnityLockfile'
    }

    It 'retains the original scene/GameObject/component/asset coverage' {
        $description | Should Match 'scene'
        $description | Should Match 'GameObject'
        $description | Should Match 'component'
        $description | Should Match 'asset'
    }

    It 'the description stays one physical line' {
        $description.Contains("`n") | Should Be $false
    }

    It 'the description is at most 1024 characters' {
        $description.Length | Should BeLessThan 1025
    }

    It 'the description contains no ": " sequence (YAML plain-scalar guard)' {
        $description | Should Not Match ':\s'
    }
}

Describe 'SKILL.md -- Tool inventory names real MCP tools (ticket #33)' {
    $toolSection = Get-Section -Text $global:skillmd_text -Heading '## Tool inventory'
    $realTools = @('manage_scene', 'find_gameobjects', 'manage_gameobject', 'manage_components',
        'manage_asset', 'manage_editor', 'manage_camera', 'read_console', 'execute_code',
        'run_tests', 'get_test_job', 'manage_build', 'refresh_unity', 'manage_tools',
        'batch_execute', 'manage_script')

    It 'the Tool inventory section names every real MCP tool identifier' {
        foreach ($tool in $realTools) {
            $toolSection.Contains($tool) | Should Be $true
        }
    }

    It 'no longer disclaims that method identifiers are defined upstream' {
        $global:skillmd_text.Contains('the exact MCP method identifiers are defined by') | Should Be $false
    }

    It 'none of the invented capability-area labels survive anywhere in the file' {
        $inventedLabels = @('Scene inspection', 'GameObject queries', 'Component read', 'Component write',
            'Asset listing', 'Asset inspection', 'Play-mode control', 'Script / console access')
        foreach ($label in $inventedLabels) {
            $global:skillmd_text.Contains($label) | Should Be $false
        }
    }

    It 'documents the component-read resource path' {
        $toolSection | Should Match 'mcpforunity://scene/gameobject'
    }

    It 'states the tool-name provenance' {
        $toolSection | Should Match 'mcpforunityserver'
    }

    It 'names the gated tool groups' {
        $toolSection | Should Match 'scripting_ext'
        $toolSection | Should Match 'testing'
    }

    It 'closes with a pointer to manage_tools for the omitted domain tools' {
        $toolSection | Should Match 'manage_tools'
    }
}

Describe 'SKILL.md -- recipes call tools by name (ticket #33)' {
    $recipesSection = Get-Section -Text $global:skillmd_text -Heading '## Patterns and recipes'

    It 'the Play-mode recipe names manage_editor' {
        $recipesSection | Should Match 'manage_editor'
    }

    It 'recipes name manage_components' {
        $recipesSection | Should Match 'manage_components'
    }

    It 'recipes name manage_asset' {
        $recipesSection | Should Match 'manage_asset'
    }

    It 'recipes name manage_scene' {
        $recipesSection | Should Match 'manage_scene'
    }

    It 'recipes name find_gameobjects' {
        $recipesSection | Should Match 'find_gameobjects'
    }

    It 'recipes name manage_camera' {
        $recipesSection | Should Match 'manage_camera'
    }

    It 'the screenshot recipe still names execute_code (Q2 preservation guard)' {
        $recipesSection | Should Match 'execute_code'
    }

    It 'the screenshot recipe C# fallback markers are intact (Q2 preservation guard)' {
        $recipesSection | Should Match 'ScreenCapture'
        $recipesSection | Should Match 'EncodeToPNG'
        $recipesSection | Should Match '\[VisualVerify\] Screenshot saved'
    }
}

Describe 'SKILL.md -- existence-based ownership of worktree-setup.yml (ticket #37)' {

    It 'does not claim that -Force flips isolation' {
        $global:skillmd_text | Should Not Match 'Force.{0,40}flip'
        $global:skillmd_text | Should Not Match 'flip.{0,40}isolation'
    }

    It 'does not claim -Force appends the managed block to a contract with no start/stop' {
        $global:skillmd_text | Should Not Match 'appending to a contract'
    }

    It 'states the file is created only when absent' {
        $global:skillmd_text | Should Match 'the file is absent, it creates it'
    }

    It 'states the file is never written to once it exists, under any flag' {
        $global:skillmd_text | Should Match 'never write[s]? to it again'
        $global:skillmd_text | Should Match 'under any flag'
    }
}

Describe 'SKILL.md -- no content inspection of an existing worktree-setup.yml (ticket #39)' {

    It 'does not claim the prepare-script warns and prints an advisory' {
        $global:skillmd_text | Should Not Match 'warns and prints'
    }

    It 'does not claim the prepare-script prints the current template' {
        $global:skillmd_text | Should Not Match 'prints the current template'
    }

    It 'still documents the manual-merge-by-hand workaround' {
        $global:skillmd_text | Should Match 'by hand'
    }

    # #37 phrase guards must still hold after the #39 rewrite.
    It 'still does not claim that -Force flips isolation' {
        $global:skillmd_text | Should Not Match 'Force.{0,40}flip'
        $global:skillmd_text | Should Not Match 'flip.{0,40}isolation'
    }

    It 'still does not claim -Force appends the managed block to a contract with no start/stop' {
        $global:skillmd_text | Should Not Match 'appending to a contract'
    }
}

# --- ticket #41: cross-reference to the new unity-yaml-merge skill ---------

Describe 'SKILL.md -- cross-references unity-yaml-merge; frontmatter stays clean (ticket #41)' {
    $section     = Get-Section -Text $global:skillmd_text -Heading '## What this skill is for'
    $description = Get-FrontmatterDescription -Text $global:skillmd_text

    It '"What this skill is for" points to the unity-yaml-merge skill for git-merging serialized assets' {
        $section | Should Match 'unity-yaml-merge'
    }

    It 'frontmatter description stays free of merge-driver phrasing (disjoint trigger surfaces)' {
        $description | Should Not Match '(?i)unityyamlmerge|merge driver|gitattributes'
    }
}
