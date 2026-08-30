#Requires -Version 5.1
<#
.SYNOPSIS
  SessionStart hook shim (ticket #47): adopts a Unity Hub-started editor for
  the current checkout, with no agent action required - Claude Code only
  (Codex has no hook surface; see skills/unity-wrapper/SKILL.md's "Unity Hub
  adoption" section for the Codex-side equivalent).

.DESCRIPTION
  Delegates to the target project's generated .seretos/unity-mcp-launch.ps1
  with -AdoptOnly, which only runs the adoption/cleanup preamble and never
  launches Unity itself. Exits 0 silently - no output at all - when the
  target project has not been prepared for the Unity MCP bridge (no
  .seretos/unity-mcp-launch.ps1 yet), so a non-Unity project produces no hook
  noise.
#>

$ErrorActionPreference = 'Stop'

$projectDir = $env:CLAUDE_PROJECT_DIR
if ([string]::IsNullOrWhiteSpace($projectDir)) { exit 0 }

$launchScriptPath = Join-Path $projectDir '.seretos/unity-mcp-launch.ps1'
if (-not (Test-Path -LiteralPath $launchScriptPath)) { exit 0 }

& $launchScriptPath -AdoptOnly -CheckoutPath $projectDir
exit 0
