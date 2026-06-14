<#
.SYNOPSIS
  Idempotent, repo-level preparation for per-worktree Unity instances.

.DESCRIPTION
  Ticket #3 (per-worktree Unity instances). Run this ONCE at the root of a Unity
  project repository. It prepares the repo so that `agent-worktree`'s
  `worktree_start` / `worktree_stop` bring a per-worktree, headless Unity Editor up
  and down, each bound to its own session's MCP server via status-dir isolation.

  Because a worktree is a checkout of the same repo, everything this script writes is
  tracked repo content that inherits to every future worktree automatically - so you
  prepare once at repo level, not per worktree. Commit the changes afterwards.

  The script only fills gaps and never clobbers an existing, foreign configuration.
  Re-running it is a no-op once the repo is fully prepared.

  What it ensures:
    1. `.seretos/worktree-setup.yml` carries a managed `start:`/`stop:` block with two
       named start variants: `default` (headless, `-batchmode -nographics`) and `gui`
       (visible editor). Both use `-projectPath <worktree>`,
       `UNITY_MCP_STATUS_DIR=<worktree>/.unity-mcp` (absolute) and
       `-executeMethod MCPForUnity.Editor.McpCiBoot.StartStdioForCi` so the in-editor
       bridge boots and writes its status file into the worktree-local status dir.
       `isolation` is forced to `full` (the contract forbids start/stop under `none`).
    2. The Unity MCP bridge package (`com.coplaydev.unity-mcp`) is referenced in
       `Packages/manifest.json`.
    3. `.gitignore` ignores the runtime `.unity-mcp/` status dir.

.PARAMETER RepoRoot
  Target Unity repository root. Defaults to `git rev-parse --show-toplevel` (works
  inside a worktree - its `.git` is a file, not a dir), falling back to the current
  directory.

.PARAMETER UnityMcpVersion
  Version tag for the bridge package / status-dir contract. Defaults to 9.7.1 to match
  the MCP server pin in the plugin manifests.

.PARAMETER Force
  Allow rewriting the managed block and flipping `isolation` to `full` when an existing
  contract conflicts. Without it, conflicts are reported and left untouched.

.NOTES
  Requires PowerShell 7+ for the launched start/stop steps (they run via `shell: pwsh`).
  The prepare-script itself runs under Windows PowerShell 5.1 or PowerShell 7+.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$UnityMcpVersion = '9.7.1',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# PowerShell 5.1 does not define $IsWindows; treat its absence as Windows.
$script:OnWindows = if ($null -ne $IsWindows) { $IsWindows } else { $true }

function Write-Info  { param($m) Write-Host "[prepare-unity-worktree] $m" }
function Write-Warn2 { param($m) Write-Warning "[prepare-unity-worktree] $m" }

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# --- Resolve repo root --------------------------------------------------------
if (-not $RepoRoot) {
    try {
        $top = (& git rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $top) { $RepoRoot = $top.Trim() }
    } catch { }
}
if (-not $RepoRoot) { $RepoRoot = (Get-Location).Path }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
Write-Info "Repo root: $RepoRoot"

if (-not (Test-Path (Join-Path $RepoRoot 'ProjectSettings'))) {
    Write-Warn2 "No 'ProjectSettings/' under repo root - this may not be a Unity project. Continuing anyway."
}

# Markers delimiting the block this script owns inside worktree-setup.yml.
$startMarker = '# >>> agent-unity-wrapper managed: per-worktree Unity bridge (do not edit between markers)'
$endMarker   = '# <<< agent-unity-wrapper managed'

# The managed start/stop block. Single-quoted here-string: NO interpolation - every
# `$` below belongs to the pwsh that the worktree runner executes at start/stop time,
# not to this prepare-script.
$managedBlock = @'
# >>> agent-unity-wrapper managed: per-worktree Unity bridge (do not edit between markers)
start:
  - name: default
    shell: pwsh
    run: |
      $ErrorActionPreference = 'Stop'
      $proj = (Get-Location).Path
      $statusDir = Join-Path $proj '.unity-mcp'
      New-Item -ItemType Directory -Force -Path $statusDir | Out-Null
      # Resolve the Unity Editor: UNITY_EDITOR_PATH wins; else derive from
      # ProjectVersion.txt against the Unity Hub default install location.
      $editor = $env:UNITY_EDITOR_PATH
      if ([string]::IsNullOrWhiteSpace($editor)) {
          $verFile = Join-Path $proj 'ProjectSettings/ProjectVersion.txt'
          if (-not (Test-Path $verFile)) {
              throw "UNITY_EDITOR_PATH unset and ProjectSettings/ProjectVersion.txt not found"
          }
          $verLine = Get-Content $verFile | Where-Object { $_ -match '^m_EditorVersion:' } | Select-Object -First 1
          $ver = ($verLine -replace 'm_EditorVersion:\s*', '').Trim()
          if ($IsWindows)    { $editor = "C:/Program Files/Unity/Hub/Editor/$ver/Editor/Unity.exe" }
          elseif ($IsMacOS)  { $editor = "/Applications/Unity/Hub/Editor/$ver/Unity.app/Contents/MacOS/Unity" }
          else               { $editor = "$HOME/Unity/Hub/Editor/$ver/Editor/Unity" }
      }
      if (-not (Test-Path $editor)) {
          throw "Unity Editor not found at '$editor' - set UNITY_EDITOR_PATH to your editor binary"
      }
      # Status-dir isolation: both the editor bridge and the session MCP server must
      # point at this exact ABSOLUTE dir so the server discovers exactly one instance
      # and auto-connects with no UI step.
      $env:UNITY_MCP_STATUS_DIR = $statusDir
      $env:UNITY_MCP_ALLOW_BATCH = '1'
      $log = Join-Path $statusDir 'editor.log'
      $unityArgs = @(
          '-batchmode', '-nographics',
          '-logFile', $log,
          '-projectPath', $proj,
          '-executeMethod', 'MCPForUnity.Editor.McpCiBoot.StartStdioForCi'
      )
      if (-not [string]::IsNullOrWhiteSpace($env:UNITY_WORKTREE_CACHE_SERVER)) {
          $unityArgs += @('-EnableCacheServer', '-cacheServerEndpoint', $env:UNITY_WORKTREE_CACHE_SERVER)
          Write-Host "UNITY_WORKTREE_CACHE_SERVER=$($env:UNITY_WORKTREE_CACHE_SERVER): enabling asset cache server"
      }
      $p = Start-Process -FilePath $editor -ArgumentList $unityArgs -PassThru
      Set-Content -Path (Join-Path $statusDir 'unity.pid') -Value $p.Id
      Write-Host "Unity bridge launched headless (pid $($p.Id)) -> $statusDir"
  - name: gui
    shell: pwsh
    run: |
      $ErrorActionPreference = 'Stop'
      $proj = (Get-Location).Path
      $statusDir = Join-Path $proj '.unity-mcp'
      New-Item -ItemType Directory -Force -Path $statusDir | Out-Null
      # Resolve the Unity Editor: UNITY_EDITOR_PATH wins; else derive from
      # ProjectVersion.txt against the Unity Hub default install location.
      $editor = $env:UNITY_EDITOR_PATH
      if ([string]::IsNullOrWhiteSpace($editor)) {
          $verFile = Join-Path $proj 'ProjectSettings/ProjectVersion.txt'
          if (-not (Test-Path $verFile)) {
              throw "UNITY_EDITOR_PATH unset and ProjectSettings/ProjectVersion.txt not found"
          }
          $verLine = Get-Content $verFile | Where-Object { $_ -match '^m_EditorVersion:' } | Select-Object -First 1
          $ver = ($verLine -replace 'm_EditorVersion:\s*', '').Trim()
          if ($IsWindows)    { $editor = "C:/Program Files/Unity/Hub/Editor/$ver/Editor/Unity.exe" }
          elseif ($IsMacOS)  { $editor = "/Applications/Unity/Hub/Editor/$ver/Unity.app/Contents/MacOS/Unity" }
          else               { $editor = "$HOME/Unity/Hub/Editor/$ver/Editor/Unity" }
      }
      if (-not (Test-Path $editor)) {
          throw "Unity Editor not found at '$editor' - set UNITY_EDITOR_PATH to your editor binary"
      }
      # Status-dir isolation: both the editor bridge and the session MCP server must
      # point at this exact ABSOLUTE dir so the server discovers exactly one instance
      # and auto-connects with no UI step.
      $env:UNITY_MCP_STATUS_DIR = $statusDir
      $env:UNITY_MCP_ALLOW_BATCH = '1'
      $log = Join-Path $statusDir 'editor.log'
      $unityArgs = @(
          '-logFile', $log,
          '-projectPath', $proj,
          '-executeMethod', 'MCPForUnity.Editor.McpCiBoot.StartStdioForCi'
      )
      if (-not [string]::IsNullOrWhiteSpace($env:UNITY_WORKTREE_CACHE_SERVER)) {
          $unityArgs += @('-EnableCacheServer', '-cacheServerEndpoint', $env:UNITY_WORKTREE_CACHE_SERVER)
          Write-Host "UNITY_WORKTREE_CACHE_SERVER=$($env:UNITY_WORKTREE_CACHE_SERVER): enabling asset cache server"
      }
      $p = Start-Process -FilePath $editor -ArgumentList $unityArgs -PassThru
      Set-Content -Path (Join-Path $statusDir 'unity.pid') -Value $p.Id
      Write-Host "Unity bridge launched with visible editor (pid $($p.Id)) -> $statusDir"
stop:
  - name: mcp-unity-bridge-stop
    shell: pwsh
    run: |
      $ErrorActionPreference = 'SilentlyContinue'
      $proj = (Get-Location).Path
      $statusDir = Join-Path $proj '.unity-mcp'
      $pidFile = Join-Path $statusDir 'unity.pid'
      if (Test-Path $pidFile) {
          $unityPid = (Get-Content $pidFile | Select-Object -First 1)
          if ($unityPid) {
              $unityPid = $unityPid.Trim()
              if ($IsWindows) {
                  Start-Process -FilePath 'taskkill' -ArgumentList @('/PID', $unityPid, '/T', '/F') -NoNewWindow -Wait
              } else {
                  & kill -TERM $unityPid 2>$null
              }
          }
          Remove-Item -Force $pidFile
      }
# <<< agent-unity-wrapper managed
'@

# Freshly-created contract (when no .seretos/worktree-setup.yml exists yet).
$freshContract = @"
version: 1
isolation: full

$managedBlock
"@

# --- 1. .seretos/worktree-setup.yml ------------------------------------------
$setupPath = Join-Path $RepoRoot '.seretos/worktree-setup.yml'
if (-not (Test-Path $setupPath)) {
    Write-Utf8NoBom -Path $setupPath -Content $freshContract
    Write-Info "Created .seretos/worktree-setup.yml with managed Unity start/stop block."
}
else {
    $content = Get-Content -LiteralPath $setupPath -Raw
    if ($content -match [regex]::Escape($startMarker)) {
        if ($Force) {
            # Literal splice: replace everything from the start marker through the end marker.
            $sIdx = $content.IndexOf($startMarker)
            $eIdx = $content.IndexOf($endMarker, $sIdx)
            if ($sIdx -ge 0 -and $eIdx -ge 0) {
                $eEnd = $eIdx + $endMarker.Length
                $content = $content.Substring(0, $sIdx) + $managedBlock + $content.Substring($eEnd)
                Write-Utf8NoBom -Path $setupPath -Content $content
                Write-Info "Refreshed managed Unity block (-Force)."
            }
        } else {
            Write-Info "Managed Unity block already present - nothing to do (use -Force to refresh)."
            # Detect old blocks that pre-date named-variant start steps (name: default / name: gui).
            $blockStart = $content.IndexOf($startMarker)
            $blockEnd   = $content.IndexOf($endMarker, $blockStart)
            if ($blockStart -ge 0 -and $blockEnd -ge 0) {
                $existingBlock = $content.Substring($blockStart, ($blockEnd + $endMarker.Length) - $blockStart)
                if ($existingBlock -match 'UNITY_WORKTREE_GUI' -or
                    $existingBlock -notmatch 'name: gui' -or
                    $existingBlock -notmatch 'UNITY_WORKTREE_CACHE_SERVER') {
                    Write-Warn2 "The existing managed block is outdated (predates named-variant start steps or cache server support). Re-run with -Force to refresh the block and enable named-variant steps (default/gui) and cache server support."
                }
            }
        }
    }
    elseif ($content -match '(?m)^\s*(start|stop)\s*:') {
        Write-Warn2 "Existing foreign 'start:'/'stop:' block found in .seretos/worktree-setup.yml - not clobbering."
        Write-Warn2 "Merge the following managed block by hand (and ensure 'isolation: full'):"
        Write-Host ""
        Write-Host $managedBlock
        Write-Host ""
        throw "Manual merge required for .seretos/worktree-setup.yml"
    }
    else {
        # No start/stop yet. Ensure isolation: full, then append the managed block.
        if ($content -match '(?m)^\s*isolation\s*:\s*full\s*$') {
            # already full
        }
        elseif ($content -match '(?m)^\s*isolation\s*:\s*(none|partial)\s*$') {
            if ($Force) {
                $content = [regex]::Replace($content, '(?m)^\s*isolation\s*:\s*(none|partial)\s*$', 'isolation: full')
                Write-Info "Flipped isolation to 'full' (-Force)."
            } else {
                throw "Contract has 'isolation: $($Matches[1])' but start/stop require 'isolation: full'. Re-run with -Force to flip it."
            }
        }
        elseif ($content -notmatch '(?m)^\s*isolation\s*:') {
            $content = $content.TrimEnd() + "`nisolation: full`n"
            Write-Info "Added missing 'isolation: full'."
        }
        $content = $content.TrimEnd() + "`n`n" + $managedBlock + "`n"
        Write-Utf8NoBom -Path $setupPath -Content $content
        Write-Info "Appended managed Unity start/stop block to existing contract."
    }
}

# --- 2. Packages/manifest.json (bridge package) ------------------------------
$manifestPath = Join-Path $RepoRoot 'Packages/manifest.json'
$pkgName = 'com.coplaydev.unity-mcp'
$pkgUrl  = "https://github.com/CoplayDev/unity-mcp.git?path=/MCPForUnity#v$UnityMcpVersion"
if (Test-Path $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if (-not $manifest.dependencies) {
        $manifest | Add-Member -NotePropertyName dependencies -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $hasPkg = $manifest.dependencies.PSObject.Properties.Name -contains $pkgName
    if ($hasPkg) {
        $currentPin = $manifest.dependencies.$pkgName
        if ($currentPin -eq $pkgUrl) {
            Write-Info "Packages/manifest.json already references $pkgName at the correct version."
        } elseif ($Force) {
            $manifest.dependencies.$pkgName = $pkgUrl
            Write-Utf8NoBom -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 32))
            Write-Info "Updated $pkgName pin from '$currentPin' to '$pkgUrl' (-Force)."
        } else {
            # Extract the #fragment for a readable current-vs-expected display.
            $currentTag  = if ($currentPin  -match '#(.+)$') { $Matches[1] } else { $currentPin }
            $expectedTag = if ($pkgUrl      -match '#(.+)$') { $Matches[1] } else { $pkgUrl }
            Write-Warn2 "Packages/manifest.json references $pkgName at a different version: current='$currentTag' ($currentPin), expected='$expectedTag' ($pkgUrl). Re-run with -Force to reconcile."
        }
    } else {
        $manifest.dependencies | Add-Member -NotePropertyName $pkgName -NotePropertyValue $pkgUrl -Force
        Write-Utf8NoBom -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 32))
        Write-Info "Added $pkgName -> $pkgUrl to Packages/manifest.json."
    }
} else {
    Write-Warn2 "No Packages/manifest.json found - add the bridge package manually:"
    Write-Warn2 "  `"$pkgName`": `"$pkgUrl`""
}

# --- 3. .gitignore (.unity-mcp runtime dir) ----------------------------------
$gitignorePath = Join-Path $RepoRoot '.gitignore'
$ignoreLine = '.unity-mcp/'
$gi = if (Test-Path $gitignorePath) { Get-Content -LiteralPath $gitignorePath -Raw } else { '' }
if ($gi -match '(?m)^\s*/?\.unity-mcp/?\s*$') {
    Write-Info ".gitignore already ignores .unity-mcp/."
} else {
    $newGi = ($gi.TrimEnd() + "`n`n# Per-worktree Unity MCP status dir (agent-unity-wrapper)`n$ignoreLine`n").TrimStart("`n")
    Write-Utf8NoBom -Path $gitignorePath -Content $newGi
    Write-Info "Added $ignoreLine to .gitignore."
}

Write-Info "Done. Review and commit the changes, then worktree_start will boot Unity per worktree."
