#Requires -Version 5.1
<#
.SYNOPSIS
  Pester 3.x tests for .github/workflows/lint.yml (ticket #41). The frontmatter
  validation step previously hardcoded skills/unity-wrapper/SKILL.md, so a
  second skill (unity-yaml-merge) would ship with zero CI validation of its
  frontmatter. This guards that the step now globs every skills/*/SKILL.md,
  fails loudly if none are found, and still validates plugin.json.
  Run with:  Invoke-Pester .\tests\lint-workflow.Tests.ps1 -Verbose
#>

$global:lintwf_repoRoot = Split-Path -Parent $PSScriptRoot
$global:lintwf_path     = Join-Path $global:lintwf_repoRoot '.github\workflows\lint.yml'
$global:lintwf_text     = [System.IO.File]::ReadAllText($global:lintwf_path)

Describe 'lint.yml -- validates every skill, not just unity-wrapper (Behaviour 8)' {

    It 'does not hardcode skills/unity-wrapper/SKILL.md' {
        $global:lintwf_text.Contains('skills/unity-wrapper/SKILL.md') | Should Be $false
    }

    It 'globs over every skill directory' {
        $global:lintwf_text.Contains('skills/*/SKILL.md') | Should Be $true
    }

    It 'fails when zero SKILL.md files are found' {
        $global:lintwf_text | Should Match '(?i)no SKILL\.md files found'
    }

    It 'the error message names the offending path when frontmatter is invalid' {
        $global:lintwf_text | Should Match '::error::\{path\}'
    }

    It 'still validates plugin.json is valid JSON' {
        $global:lintwf_text | Should Match 'plugin\.json'
    }

    It 'validates the Claude plugin manifest' {
        $global:lintwf_text | Should Match 'jq empty \.claude-plugin/plugin\.json'
    }

    It 'validates the Codex plugin manifest too, not just the Claude one' {
        $global:lintwf_text | Should Match 'jq empty \.codex-plugin/plugin\.json'
    }
}
