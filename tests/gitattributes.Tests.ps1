#Requires -Version 5.1
<#
.SYNOPSIS
  Pester 3.x regression tests for .gitattributes (ticket #29 - CRLF/EOL policy).
  Run with:  Invoke-Pester .\tests\gitattributes.Tests.ps1 -Verbose

  Claude Code silently ignores instruction/skill/settings files checked out
  with CRLF (blob content is unchanged, so `git status`/`git diff` stay
  silent too). These tests guard the repo-wide `* text=auto eol=lf` default
  in .gitattributes that fixes this, including for files that do not exist
  yet - the failure mode an enumerated allowlist would re-introduce.
#>

# Resolve the repo root robustly - do not assume the ambient cwd.
$global:ga_repoRoot = Split-Path -Parent $PSScriptRoot

function Get-CheckAttr {
    param([string[]]$Attrs, [string[]]$Paths)
    $argList = @('-C', $global:ga_repoRoot, 'check-attr') + $Attrs + @('--') + $Paths
    $out = & git @argList
    $result = @{}
    foreach ($line in $out) {
        # git check-attr output format: "<path>: <attr>: <value>"
        if ($line -match '^(.*): ([^:]+): (.*)$') {
            $p = $matches[1]; $a = $matches[2]; $v = $matches[3]
            if (-not $result.ContainsKey($p)) { $result[$p] = @{} }
            $result[$p][$a] = $v
        }
    }
    return $result
}

Describe '.gitattributes -- file exists at repo root' {
    It 'exists' {
        (Test-Path (Join-Path $global:ga_repoRoot '.gitattributes')) | Should Be $true
    }
}

Describe '.gitattributes -- resolves eol=lf for every Claude-parsed file (Behaviour A)' {
    $attrs = Get-CheckAttr -Attrs @('text', 'eol') -Paths @(
        'AGENTS.md',
        'CLAUDE.md',
        '.claude/settings.json',
        'skills/unity-wrapper/SKILL.md',
        '.claude-plugin/plugin.json',
        '.codex-plugin/plugin.json'
    )

    It 'AGENTS.md resolves text=auto eol=lf' {
        $attrs['AGENTS.md']['text'] | Should Be 'auto'
        $attrs['AGENTS.md']['eol']  | Should Be 'lf'
    }
    It 'CLAUDE.md resolves text=auto eol=lf' {
        $attrs['CLAUDE.md']['text'] | Should Be 'auto'
        $attrs['CLAUDE.md']['eol']  | Should Be 'lf'
    }
    It '.claude/settings.json resolves text=auto eol=lf' {
        $attrs['.claude/settings.json']['text'] | Should Be 'auto'
        $attrs['.claude/settings.json']['eol']  | Should Be 'lf'
    }
    It 'skills/unity-wrapper/SKILL.md resolves text=auto eol=lf' {
        $attrs['skills/unity-wrapper/SKILL.md']['text'] | Should Be 'auto'
        $attrs['skills/unity-wrapper/SKILL.md']['eol']  | Should Be 'lf'
    }
    It '.claude-plugin/plugin.json resolves text=auto eol=lf' {
        $attrs['.claude-plugin/plugin.json']['text'] | Should Be 'auto'
        $attrs['.claude-plugin/plugin.json']['eol']  | Should Be 'lf'
    }
    It '.codex-plugin/plugin.json resolves text=auto eol=lf' {
        $attrs['.codex-plugin/plugin.json']['text'] | Should Be 'auto'
        $attrs['.codex-plugin/plugin.json']['eol']  | Should Be 'lf'
    }
}

Describe '.gitattributes -- covers not-yet-existing paths under .claude (Behaviour B, future-file regression)' {
    # None of these paths exist on disk. git check-attr is pure pattern
    # matching, so a pass here proves the default is a wildcard, not an
    # enumerated allowlist - an allowlist would fail every one of these,
    # which is exactly the bug this ticket exists to close.
    $attrs = Get-CheckAttr -Attrs @('eol') -Paths @(
        '.claude/agents/example.md',
        '.claude/commands/example.md',
        '.claude/skills/example/SKILL.md',
        'skills/future-skill/SKILL.md'
    )

    It '.claude/agents/example.md resolves eol=lf though it does not exist' {
        $attrs['.claude/agents/example.md']['eol'] | Should Be 'lf'
    }
    It '.claude/commands/example.md resolves eol=lf though it does not exist' {
        $attrs['.claude/commands/example.md']['eol'] | Should Be 'lf'
    }
    It '.claude/skills/example/SKILL.md resolves eol=lf though it does not exist' {
        $attrs['.claude/skills/example/SKILL.md']['eol'] | Should Be 'lf'
    }
    It 'skills/future-skill/SKILL.md resolves eol=lf though it does not exist' {
        $attrs['skills/future-skill/SKILL.md']['eol'] | Should Be 'lf'
    }
}

Describe '.gitattributes -- no tracked non-binary file contains CR bytes (Behaviour C)' {
    $trackedFiles = & git -C $global:ga_repoRoot ls-files
    $binaryAttrs  = if ($trackedFiles) { Get-CheckAttr -Attrs @('binary') -Paths $trackedFiles } else { @{} }

    $offenders = New-Object System.Collections.Generic.List[string]
    foreach ($f in $trackedFiles) {
        $isBinary = $false
        if ($binaryAttrs.ContainsKey($f) -and $binaryAttrs[$f]['binary'] -eq 'set') { $isBinary = $true }
        if ($isBinary) { continue }

        $full = Join-Path $global:ga_repoRoot $f
        if (-not (Test-Path $full -PathType Leaf)) { continue }

        $bytes = [System.IO.File]::ReadAllBytes($full)
        if ($bytes -contains 13) {
            $offenders.Add($f)
        }
    }

    It 'has zero non-binary tracked files with CR bytes' {
        if ($offenders.Count -gt 0) {
            throw "Files still containing CR bytes: $($offenders -join ', ')"
        }
        $offenders.Count | Should Be 0
    }

    It '.gitattributes itself contains no CR bytes' {
        $gaPath = Join-Path $global:ga_repoRoot '.gitattributes'
        $gaBytes = [System.IO.File]::ReadAllBytes($gaPath)
        ($gaBytes -contains 13) | Should Be $false
    }
}

Describe '.gitattributes -- assets/icon.png stays binary with an unchanged blob (Behaviour D)' {
    It 'is marked binary' {
        $attrs = Get-CheckAttr -Attrs @('binary') -Paths @('assets/icon.png')
        $attrs['assets/icon.png']['binary'] | Should Be 'set'
    }

    It 'working-tree blob hash matches HEAD (no re-normalization rewrote it)' {
        $wtHash   = (& git -C $global:ga_repoRoot hash-object assets/icon.png | Out-String).Trim()
        $headHash = (& git -C $global:ga_repoRoot rev-parse 'HEAD:assets/icon.png' | Out-String).Trim()
        $wtHash | Should Be $headHash
    }
}
