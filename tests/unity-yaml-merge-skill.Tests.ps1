#Requires -Version 5.1
<#
.SYNOPSIS
  Pester 3.x tests for skills/unity-yaml-merge/SKILL.md (ticket #41). This is
  a second, standalone skill carrying generic Unity-tooling knowledge about
  git-merging Unity YAML assets through the UnityYAMLMerge (SmartMerge)
  driver. The load-bearing fact is that a driver-resolved conflict leaves NO
  `<<<<<<<` markers, so a naive "grep for markers" check silently reports a
  clean merge that may not be clean. The skill's job is to expose the merge
  mechanism completely and mechanically (detection, wiring, invocation,
  resolution) for autonomous, unattended runs, with zero escalation policy -
  when to involve a human is the consuming project's decision, never this
  skill's.
  Run with:  Invoke-Pester .\tests\unity-yaml-merge-skill.Tests.ps1 -Verbose
#>

$global:yamlmerge_repoRoot = Split-Path -Parent $PSScriptRoot
$global:yamlmerge_path     = Join-Path $global:yamlmerge_repoRoot 'skills\unity-yaml-merge\SKILL.md'
$global:yamlmerge_exists   = Test-Path $global:yamlmerge_path
$global:yamlmerge_text     = if ($global:yamlmerge_exists) { [System.IO.File]::ReadAllText($global:yamlmerge_path) } else { '' }

# Returns the single "description:" line's value from the leading frontmatter
# block (text between the opening --- and the next \n---), key stripped.
# Returns '' if no such block/line is found. Copied from tests/skill-md.Tests.ps1.
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
# including) the next top-level "## " heading. Copied from tests/skill-md.Tests.ps1.
function Get-Section {
    param([string]$Text, [string]$Heading)
    $sIdx = $Text.IndexOf($Heading)
    if ($sIdx -eq -1) { return '' }
    $eIdx = $Text.IndexOf("`n## ", $sIdx + $Heading.Length)
    if ($eIdx -eq -1) { return $Text.Substring($sIdx) }
    return $Text.Substring($sIdx, $eIdx - $sIdx)
}

# --- Behaviour 1: the skill exists and triggers on merge intent, not the tool name ---

Describe 'unity-yaml-merge SKILL.md -- exists and triggers on intent (Behaviour 1)' {

    It 'the skill file exists' {
        $global:yamlmerge_exists | Should Be $true
    }

    It 'starts with frontmatter delimiter ---' {
        $global:yamlmerge_text.TrimStart().StartsWith('---') | Should Be $true
    }

    It 'frontmatter name is unity-yaml-merge' {
        $global:yamlmerge_text | Should Match 'name: unity-yaml-merge'
    }

    It 'contains no CR bytes' {
        if (-not $global:yamlmerge_exists) { throw 'file does not exist' }
        $bytes = [System.IO.File]::ReadAllBytes($global:yamlmerge_path)
        ($bytes -contains 13) | Should Be $false
    }

    $description = Get-FrontmatterDescription -Text $global:yamlmerge_text

    It 'description matches merge intent' {
        $description | Should Match '(?i)merge'
    }

    It 'description matches conflict intent' {
        $description | Should Match '(?i)conflict'
    }

    It 'description names .prefab files' {
        $description | Should Match '\.prefab'
    }

    It 'description names .unity scene files' {
        $description | Should Match '\.unity'
    }

    It 'description names gitattributes' {
        $description | Should Match '(?i)gitattributes'
    }

    It 'description names UnityYAMLMerge (tool name is secondary, not the only trigger)' {
        $description | Should Match '(?i)unityyamlmerge'
    }

    It 'description stays one physical line' {
        $description.Contains("`n") | Should Be $false
    }

    It 'description is at most 1024 characters' {
        $description.Length | Should BeLessThan 1025
    }

    It 'description contains no colon-whitespace sequence (YAML plain-scalar guard)' {
        $description | Should Not Match ':\s'
    }
}

# --- Behaviour 2: the no-markers property and the real detection ladder ---

Describe 'unity-yaml-merge SKILL.md -- the no-markers property and detection ladder (Behaviour 2)' {

    It 'states that conflicted output has no conflict markers' {
        $global:yamlmerge_text | Should Match '(?i)no\b.{0,40}conflict marker'
    }

    It 'states that scanning for markers is the wrong check' {
        $global:yamlmerge_text | Should Match '(?i)wrong check'
    }

    It 'names git status as a detection channel' {
        $global:yamlmerge_text | Should Match 'git status'
    }

    It 'names --porcelain' {
        $global:yamlmerge_text | Should Match '--porcelain'
    }

    It 'names the UU unmerged marker' {
        $global:yamlmerge_text | Should Match '\bUU\b'
    }

    It 'names the -o flag for writing the conflict list' {
        $global:yamlmerge_text | Should Match '-o <file>'
    }

    It "names the driver's own stdout as a channel" {
        $global:yamlmerge_text | Should Match '(?i)stdout'
    }
}

# --- Behaviour 3: wiring needs both halves; one alone is a silent no-op ---

Describe 'unity-yaml-merge SKILL.md -- wiring needs both halves (Behaviour 3)' {

    $wiringSection = Get-Section -Text $global:yamlmerge_text -Heading '## Wiring the merge driver'
    # The preamble is everything in the Wiring section before the enumerated
    # incomplete-wiring case breakdown (case 1 = silent no-op, case 2 = loud
    # fatal error, case 3 = silent no-op again). Only that enumerated
    # breakdown is allowed to assert "silent no-op" -- the topline/preamble
    # sentence introducing the two required pieces must not itself claim
    # that either piece missing is unconditionally a silent no-op, since
    # case 2 (config section present but no driver line) is a loud abort,
    # not a silent no-op. This regression-tests ticket #41's re-review
    # finding, where the preamble kept asserting the unconditional claim
    # even after the case breakdown below it was corrected.
    $incompleteMarker = 'Incomplete wiring does not fail in one consistent way'
    $preambleEnd = $wiringSection.IndexOf($incompleteMarker)
    $wiringPreamble = if ($preambleEnd -eq -1) { $wiringSection } else { $wiringSection.Substring(0, $preambleEnd) }

    It 'has a non-empty Wiring the merge driver section to check' {
        $wiringSection.Length | Should BeGreaterThan 0
    }

    It 'the Wiring section preamble does not unconditionally claim either missing piece is a silent no-op' {
        # \s+ (not a literal space) because prose in this file wraps at
        # ~72 columns, so "silent" and "no-op" can legitimately land on
        # opposite sides of a line break in the raw Markdown source.
        $wiringPreamble | Should Not Match '(?i)silent\s+no-?op'
    }

    It 'names the .gitattributes merge=unityyamlmerge routing' {
        $global:yamlmerge_text | Should Match 'merge=unityyamlmerge'
    }

    It 'names the merge.unityyamlmerge.driver git config key' {
        $global:yamlmerge_text | Should Match 'merge\.unityyamlmerge\.driver'
    }

    It 'states the attribute-only case (no matching config section) is a silent no-op' {
        $global:yamlmerge_text | Should Match '(?i)silent no-?op'
    }

    It 'documents the loud fatal error when the config section exists but has no driver line' {
        $global:yamlmerge_text | Should Match 'fatal: custom merge driver \S+ lacks command line\.'
    }

    It 'documents what happens in the reverse direction (driver configured, no gitattributes routing)' {
        $global:yamlmerge_text | Should Match '(?i)reverse direction'
    }

    It 'shows the UnityYAMLMerge.exe path' {
        $global:yamlmerge_text | Should Match 'UnityYAMLMerge\.exe'
    }

    It 'names the macOS/Linux binary equivalent' {
        $global:yamlmerge_text | Should Match '(?i)macOS|Linux'
    }
}

# --- Behaviour 4: unattended-safe flags with their consequences ---

Describe 'unity-yaml-merge SKILL.md -- unattended-safe flags (Behaviour 4)' {
    $flagsSection = Get-Section -Text $global:yamlmerge_text -Heading '## Flags for unattended'

    It 'names --fallback none' {
        $global:yamlmerge_text | Should Match '--fallback none'
    }

    It 'names the default mergespecfile.txt fallback list' {
        $global:yamlmerge_text | Should Match 'mergespecfile\.txt'
    }

    It 'explains the GUI fallback hazard' {
        $global:yamlmerge_text | Should Match '(?i)gui'
    }

    It 'explains that an unattended run blocks/hangs waiting on that GUI' {
        $global:yamlmerge_text | Should Match '(?i)block|hang|never returns'
    }

    It 'the flags section names -h headless' {
        $flagsSection | Should Match '-h'
    }

    It 'the flags section names -p premerge and the base-value consequence of omitting it' {
        $flagsSection | Should Match '-p'
        $flagsSection | Should Match '(?i)base'
    }
}

# --- Behaviour 5: argument order and the git placeholder mapping ---

Describe 'unity-yaml-merge SKILL.md -- argument order and placeholder mapping (Behaviour 5)' {

    It 'contains the ordered signature' {
        $global:yamlmerge_text | Should Match 'merge \[flags\] <base> <left> <right> \[dest\]'
    }

    It 'states left = theirs' {
        $global:yamlmerge_text | Should Match 'left = theirs'
    }

    It 'states right = mine' {
        $global:yamlmerge_text | Should Match 'right = mine'
    }

    It 'contains the literal driver placeholder line' {
        if (-not $global:yamlmerge_exists) { throw 'file does not exist' }
        $global:yamlmerge_text.Contains('%O %B %A %A') | Should Be $true
    }

    It 'explains %O as the ancestor/base' {
        $global:yamlmerge_text | Should Match '%O[\s\S]{0,80}ancestor'
    }

    It 'explains %A as our version / output path' {
        $global:yamlmerge_text | Should Match '%A[\s\S]{0,150}our'
    }

    It 'explains %B as their/incoming version' {
        $global:yamlmerge_text | Should Match '%B[\s\S]{0,80}their'
    }
}

# --- Behaviour 6: mechanical resolution is exposed ---

Describe 'unity-yaml-merge SKILL.md -- mechanical conflict resolution (Behaviour 6)' {
    $resolveSection = Get-Section -Text $global:yamlmerge_text -Heading '## Resolving a conflict'

    It 'has a Resolving a conflict section' {
        $global:yamlmerge_text | Should Match '## Resolving a conflict'
    }

    It 'names git show stage 1/2/3 extraction' {
        $resolveSection | Should Match 'git show :1:'
        $resolveSection | Should Match 'git show :2:'
        $resolveSection | Should Match 'git show :3:'
    }

    It 'names checkout-index --stage=all as an alternative extraction method' {
        $resolveSection | Should Match 'checkout-index --stage=all'
    }

    It 're-runs UnityYAMLMerge merge manually on the extracted stages' {
        $resolveSection | Should Match '(?i)re-run'
        $resolveSection | Should Match 'UnityYAMLMerge merge'
    }

    It 'names git checkout --theirs and --ours' {
        $resolveSection | Should Match 'git checkout --theirs'
        $resolveSection | Should Match 'git checkout --ours'
    }

    It 'clarifies --theirs/--ours select a whole stage blob, not a per-object merge' {
        $resolveSection | Should Match '(?i)whole'
        $resolveSection | Should Match '(?i)per-object merge'
    }

    It 'names git add as the action that clears UU' {
        $resolveSection | Should Match 'git add'
    }

    It 'names git merge --abort to unwind' {
        $resolveSection | Should Match 'git merge --abort'
    }

    It 'documents exit-code semantics with a version-variance caveat' {
        $resolveSection | Should Match '(?i)exit code'
        $resolveSection | Should Match '(?i)version-dependent'
    }
}

# --- Behaviour 7: no escalation / human-handoff policy anywhere ---

Describe 'unity-yaml-merge SKILL.md -- no escalation/human-handoff policy (Behaviour 7)' {

    It 'does not use escalation language' {
        $global:yamlmerge_text | Should Not Match '(?i)escalat'
    }

    It 'does not tell the reader to ask a person' {
        $global:yamlmerge_text | Should Not Match '(?i)ask the (user|human|operator)'
    }

    It 'does not tell the reader to hand off the conflict' {
        $global:yamlmerge_text | Should Not Match '(?i)hand (it |the conflict |this )?(off|over)'
    }

    It 'does not tell the reader to defer/leave it to a human' {
        $global:yamlmerge_text | Should Not Match '(?i)(defer|leave (it|this)) to a human'
    }

    It 'does not tell the reader to surface the conflict to a human/user' {
        $global:yamlmerge_text | Should Not Match '(?i)surface.{0,40}to (a|the) (human|user)'
    }

    It 'does not require human review, intervention, or decision' {
        $global:yamlmerge_text | Should Not Match '(?i)human (review|intervention|decision)'
    }

    It 'does not say to stop and ask' {
        $global:yamlmerge_text | Should Not Match '(?i)stop and ask'
    }

    It 'does not say it requires a human' {
        $global:yamlmerge_text | Should Not Match '(?i)requires? (a )?human'
    }

    It 'does not tell the reader to involve someone else' {
        $global:yamlmerge_text | Should Not Match '(?i)involve\s+(someone|somebody|another\s+person|anyone|a\s+person)'
    }

    It 'does not frame a decision as belonging to a third party outside this skill' {
        $global:yamlmerge_text | Should Not Match '(?i)(is|not)\s+a\s+decision\s+for\s+(the\s+)?(calling\s+project|someone|somebody|another\s+person|anyone|a\s+person|the\s+(user|human|operator))'
    }

    It 'does describe unattended/autonomous operation (positive control)' {
        $global:yamlmerge_text | Should Match '(?i)unattended|autonomous'
    }
}
