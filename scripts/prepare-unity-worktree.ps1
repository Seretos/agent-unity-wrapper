<#
.SYNOPSIS
  Idempotent, repo-level preparation for per-worktree Unity instances.

.DESCRIPTION
  Ticket #3 (per-worktree Unity instances); migrated in ticket #47 to the
  `agent-worktree` Environment model. Run this ONCE at the root of a Unity
  project repository. It prepares the repo so that `agent-worktree`'s
  `environment_start` / `environment_stop` bring a per-environment (linked
  worktree, or the main checkout via `checkout_path=<repo root>`), headless
  Unity Editor up and down, each bound to its own session's MCP server via
  status-dir isolation.

  Because a worktree is a checkout of the same repo, everything this script writes is
  tracked repo content that inherits to every future worktree automatically - so you
  prepare once at repo level, not per worktree. Commit the changes afterwards.

  `.seretos/worktree-setup.yml` is created only when absent. Once the file exists -
  whether it carries the managed block, a foreign contract, or no start:/stop: at all -
  the script never touches it again, under any flag or condition: no read, no append,
  no isolation flip, no reconcile, no advisory. Existence (`Test-Path`) is the only
  check ever made; the script does not open the file, so it cannot and does not
  comment on its contents. Re-running is a no-op once the repo is fully prepared.

  `.seretos/unity-mcp-launch.ps1` is the opposite ownership model (ticket #47):
  it is generated content owned outright by this plugin and is **always
  overwritten** on every run - even without `-Force` - carrying a
  "do not hand-edit" header. It holds the actual launch + Unity Hub-adoption
  logic shared by both the managed `start:` steps and the SessionStart hook
  (`hooks/session-start-adopt.ps1`), since a repo-local generated file is the
  only location both callers can reach.

  What it ensures:
    1. `.seretos/worktree-setup.yml` carries a managed `start:`/`stop:` block with two
       named start variants: `default` (headless) and `gui` (visible editor), each a
       thin call into `.seretos/unity-mcp-launch.ps1 -Variant <default|gui>` (below).
       `isolation` is set to `full` in a freshly-created contract (the contract forbids
       start/stop under `none`); an existing file's `isolation` is never read or edited.
    2. `.seretos/unity-mcp-launch.ps1` carries the actual launch body: Unity Hub
       adoption/cleanup, the launch decision (already-connected vs. launch), editor
       resolution, `UNITY_MCP_STATUS_DIR=<checkout>/.unity-mcp` (absolute), the
       `-executeMethod MCPForUnity.Editor.McpCiBoot.StartStdioForCi` boot, the Library
       mirror, the cache-server flags, and the `unity.pid` file. Always regenerated.
    3. The Unity MCP bridge package (`com.coplaydev.unity-mcp`) is referenced in
       `Packages/manifest.json`.
    4. `.gitignore` ignores the runtime `.unity-mcp/` status dir.

.PARAMETER RepoRoot
  Target Unity repository root. Defaults to `git rev-parse --show-toplevel` (works
  inside a worktree - its `.git` is a file, not a dir), falling back to the current
  directory.

.PARAMETER UnityMcpVersion
  Version tag for the bridge package / status-dir contract. Defaults to 9.7.1 to match
  the MCP server pin in the plugin manifests.

.PARAMETER Force
  Reconciles a mismatched `com.coplaydev.unity-mcp` pin in `Packages/manifest.json`.
  Without it, a version mismatch is reported and left untouched. -Force has no effect on
  `.seretos/worktree-setup.yml`: that file is created only when absent, and once it
  exists - with a managed block, a foreign contract, or no `start:`/`stop:` at all - it
  is never read or written to, by any flag. Existence, not content, is the only thing
  that is ever checked.

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

# The managed start/stop block. Single-quoted here-string: NO interpolation - every
# `$` below belongs to the pwsh that the worktree runner executes at start/stop time,
# not to this prepare-script.
$managedBlock = @'
# >>> agent-unity-wrapper managed: per-worktree Unity bridge (generated by agent-unity-wrapper; this project owns this block - edit it freely)
start:
  - name: default
    shell: pwsh
    run: |
      $ErrorActionPreference = 'Stop'
      $proj = if ($env:WORKTREE_PATH) { $env:WORKTREE_PATH } else { (Get-Location).Path }
      & (Join-Path $proj '.seretos/unity-mcp-launch.ps1') -Variant default -CheckoutPath $proj
  - name: gui
    shell: pwsh
    run: |
      $ErrorActionPreference = 'Stop'
      $proj = if ($env:WORKTREE_PATH) { $env:WORKTREE_PATH } else { (Get-Location).Path }
      & (Join-Path $proj '.seretos/unity-mcp-launch.ps1') -Variant gui -CheckoutPath $proj
stop:
  - name: mcp-unity-bridge-stop
    shell: pwsh
    run: |
      $ErrorActionPreference = 'SilentlyContinue'
      $proj = if ($env:WORKTREE_PATH) { $env:WORKTREE_PATH } else { (Get-Location).Path }
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

# Shared launch + Unity Hub-adoption body (ticket #47). Written into
# <repo>/.seretos/unity-mcp-launch.ps1 (always overwritten - see step 4 below).
# Single-quoted here-string: every `$` below belongs to the pwsh that later
# runs this file, not to this prepare-script. Reached from two call sites:
# the managed start: steps above (-Variant default|gui) and the SessionStart
# hook (hooks/session-start-adopt.ps1, -AdoptOnly) - one algorithm, not two.
$launchScript = @'
# >>> agent-unity-wrapper generated: unity-mcp-launch.ps1 - do not hand-edit; re-run scripts/prepare-unity-worktree.ps1 to update
<#
.SYNOPSIS
  Shared Unity MCP launch + Unity Hub-adoption logic (ticket #47).

.DESCRIPTION
  Generated into <repo>/.seretos/unity-mcp-launch.ps1 by
  scripts/prepare-unity-worktree.ps1 - always regenerated on every run, never
  hand-edited (unlike .seretos/worktree-setup.yml, which stays
  existence-based - see that script's header).

  Two entry points call into this same file:
    - The managed start: steps (default/gui) run it as a full launch:
        & unity-mcp-launch.ps1 -Variant <default|gui> -CheckoutPath <path>
      This runs the Hub-adoption preamble, decides whether a live editor is
      already connected (adopted or this session's own prior instance), and
      launches Unity only when neither is true.
    - hooks/session-start-adopt.ps1 (Claude Code SessionStart hook) runs it
      adoption-only, so a Hub-started editor is discovered with no agent
      action and Unity is never launched by the hook itself:
        & unity-mcp-launch.ps1 -AdoptOnly -CheckoutPath <path>
#>
param(
    [ValidateSet('default', 'gui')]
    [string]$Variant = 'default',
    [string]$CheckoutPath,
    [switch]$AdoptOnly,
    [string]$GlobalStatusDir = (Join-Path $HOME '.unity-mcp')
)

$ErrorActionPreference = 'Stop'
$script:OnWindows = if ($null -ne $IsWindows) { $IsWindows } else { $true }

# Adoption liveness thresholds - named script constants so both entry points
# agree and a test can name the boundary it exercises.
$HeartbeatMaxAgeSeconds = 60
$PortProbeTimeoutMs     = 500

function Test-TcpPortOpen {
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 500
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        try { $client.EndConnect($async) } catch { return $false }
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-StatusFileHeartbeatAgeSeconds {
    # ConvertFrom-Json auto-detects an ISO-8601 "Z" string and hands back an
    # already-parsed [datetime] rather than a string - stringifying it first
    # (via ToString()) and re-parsing loses the 'Z'/offset and silently drops
    # to Kind=Unspecified, which ToUniversalTime() then mis-shifts by the
    # local timezone offset. Use the [datetime] directly when we already have
    # one; only Parse a plain string. Either way, an Unspecified Kind here
    # means the numeric clock value IS the UTC wall-clock reading (the "Z"
    # was simply not preserved as a Kind tag) - retag it Utc, do not shift it.
    #
    # Field names verified against the real mcpforunityserver==9.7.1 wheel
    # (review round 3 "needs verification" finding): the status file JSON
    # written/read by the wrapped server uses `last_heartbeat`, not
    # `heartbeat` (transport/legacy/port_discovery.py, both
    # discover_all_unity_instances() and discover_unity_port() read
    # data.get('last_heartbeat')). Confirmed by downloading and inspecting
    # the actual published wheel - see the change report for the exact
    # source lines.
    param([Parameter(Mandatory)]$Data)
    $raw = $Data.last_heartbeat
    $hb = if ($raw -is [datetime]) { $raw } else {
        [datetime]::Parse([string]$raw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    }
    if ($hb.Kind -eq [System.DateTimeKind]::Unspecified) {
        $hb = [datetime]::SpecifyKind($hb, [System.DateTimeKind]::Utc)
    }
    return ((Get-Date).ToUniversalTime() - $hb.ToUniversalTime()).TotalSeconds
}

function Test-StatusFileLive {
    # Shared liveness predicate (heartbeat age + port probe) for a single
    # status file, factored out so Invoke-UnityMcpAdoption's "is the existing
    # real status file actually live" check and Get-UnityMcpLaunchDecision's
    # scan agree on exactly one definition of "live" (review round 1 finding).
    param(
        [Parameter(Mandatory)][string]$StatusFilePath,
        [int]$HeartbeatMaxAgeSeconds = $HeartbeatMaxAgeSeconds,
        [int]$PortProbeTimeoutMs = $PortProbeTimeoutMs
    )
    $data = $null
    try { $data = Get-Content -LiteralPath $StatusFilePath -Raw | ConvertFrom-Json } catch { return $false }
    # Field names: last_heartbeat / unity_port, not heartbeat / port - see
    # Get-StatusFileHeartbeatAgeSeconds's header comment (review round 3
    # verified-against-upstream fix).
    if (-not $data.last_heartbeat -or -not $data.unity_port) { return $false }
    $age = $null
    try { $age = Get-StatusFileHeartbeatAgeSeconds -Data $data } catch { return $false }
    if ($age -gt $HeartbeatMaxAgeSeconds) { return $false }
    # A malformed/non-numeric port (partially written or corrupted status
    # file) must be treated as "not live", not allowed to throw a
    # terminating exception - the generated launch script runs under
    # $ErrorActionPreference = 'Stop', so an unguarded [int] cast here would
    # otherwise abort every caller's scanning loop, not just this one file
    # (review round 2 blocking finding).
    $port = $null
    try { $port = [int]$data.unity_port } catch { return $false }
    if (-not (Test-TcpPortOpen -Port $port -TimeoutMs $PortProbeTimeoutMs)) { return $false }
    return $true
}

function Test-EntryIsLink {
    # Self-identifying reparse-point check - no marker file. Works for both
    # PS7's LinkType property and PS 5.1's Attributes bitmask.
    param([Parameter(Mandatory)]$Entry)
    if ($Entry.PSObject.Properties.Name -contains 'LinkType' -and $Entry.LinkType) { return $true }
    if ($Entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $true }
    return $false
}

function Find-AdoptionCandidate {
    param(
        [Parameter(Mandatory)][string]$CheckoutPath,
        [Parameter(Mandatory)][string]$GlobalStatusDir,
        [int]$HeartbeatMaxAgeSeconds = $HeartbeatMaxAgeSeconds,
        [int]$PortProbeTimeoutMs = $PortProbeTimeoutMs
    )
    if (-not (Test-Path -LiteralPath $GlobalStatusDir)) { return $null }
    $targetAssets = (Join-Path $CheckoutPath 'Assets').TrimEnd('\', '/').Replace('\', '/')
    $candidates = Get-ChildItem -LiteralPath $GlobalStatusDir -Filter 'unity-mcp-status-*.json' -File -ErrorAction SilentlyContinue
    foreach ($sf in $candidates) {
        $data = $null
        try { $data = Get-Content -LiteralPath $sf.FullName -Raw | ConvertFrom-Json } catch { continue }
        if (-not $data.project_path) { continue }
        $candidatePath = ([string]$data.project_path).TrimEnd('\', '/').Replace('\', '/')
        # -ne here relies on PowerShell's default culture-invariant, case-insensitive
        # string comparison (only -cne is case-sensitive) - intentional, not an oversight,
        # so a Windows drive-letter/casing difference still matches.
        if ($candidatePath -ne $targetAssets) { continue }
        # Field names: last_heartbeat / unity_port, not heartbeat / port - see
        # Get-StatusFileHeartbeatAgeSeconds's header comment (review round 3
        # verified-against-upstream fix).
        if (-not $data.last_heartbeat) { continue }
        $age = $null
        try { $age = Get-StatusFileHeartbeatAgeSeconds -Data $data } catch { continue }
        if ($age -gt $HeartbeatMaxAgeSeconds) { continue }
        if (-not $data.unity_port) { continue }
        # Same malformed-port guard as Test-StatusFileLive above: a
        # non-numeric port must be skipped (treated as "not a match"), not
        # allowed to throw and abort the scan of every other candidate
        # (review round 2 blocking finding).
        $port = $null
        try { $port = [int]$data.unity_port } catch { continue }
        if (-not (Test-TcpPortOpen -Port $port -TimeoutMs $PortProbeTimeoutMs)) { continue }
        $portFileName = $sf.Name -replace 'status', 'port'
        $portFile = Join-Path $GlobalStatusDir $portFileName
        # A cleanup race (the candidate's editor exits between this scan and the
        # symlink step) can leave the status file behind with its port file
        # already gone - verify the derived port file still exists before
        # returning this candidate, or a dangling symlink is manufactured (the
        # hazard documented in docs/upstream/coplaydev-port-discovery-stat-guard.md).
        if (-not (Test-Path -LiteralPath $portFile)) { continue }
        return @{ StatusFile = $sf.FullName; PortFile = $portFile }
    }
    return $null
}

function New-AdoptionSymlink {
    # Thin, side-effecting wrapper around New-Item -ItemType SymbolicLink so
    # it can be mocked (e.g. to simulate a denied symlink without needing
    # real Developer Mode/admin privilege). Only ever removes an existing
    # entry at LinkPath when it is itself a symlink/reparse-point
    # (Test-EntryIsLink) - same gate Remove-StaleAdoptionLinks already uses.
    # A real (non-link) file already occupying LinkPath must never be
    # clobbered: since Invoke-UnityMcpAdoption now deliberately proceeds past
    # a stale real status file instead of returning early, a same-named Hub
    # candidate's adoption could otherwise silently delete that real local
    # file (review round 2 blocking finding).
    param(
        [Parameter(Mandatory)][string]$LinkPath,
        [Parameter(Mandatory)][string]$Target
    )
    $existing = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
    if ($existing) {
        if (-not (Test-EntryIsLink -Entry $existing)) {
            throw "Refusing to adopt: a real (non-symlink) file already exists at '$LinkPath'. Not overwriting it."
        }
        Remove-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target -ErrorAction Stop | Out-Null
}

function Remove-StaleAdoptionLinks {
    # Deletes every symlink/reparse-point entry in StatusDir unconditionally -
    # no marker file, self-identifying via Test-EntryIsLink. Leaves real files
    # (this session's own prior status file) untouched. Cleans up both a
    # dangling link (target deleted) and a still-live one, which the adoption
    # pass below re-creates if still warranted - cleanup is unconditional.
    param([Parameter(Mandatory)][string]$StatusDir)
    if (-not (Test-Path -LiteralPath $StatusDir)) { return }
    Get-ChildItem -LiteralPath $StatusDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if (Test-EntryIsLink -Entry $_) {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-UnityMcpAdoption {
    # The full preamble, run unconditionally by both entry points (-AdoptOnly
    # and a full launch): clean stale links, then adopt a live Hub-started
    # editor for this checkout if one exists and none is already connected.
    param(
        [Parameter(Mandatory)][string]$CheckoutPath,
        [Parameter(Mandatory)][string]$GlobalStatusDir,
        [int]$HeartbeatMaxAgeSeconds = $HeartbeatMaxAgeSeconds,
        [int]$PortProbeTimeoutMs = $PortProbeTimeoutMs
    )
    $statusDir = Join-Path $CheckoutPath '.unity-mcp'
    New-Item -ItemType Directory -Force -Path $statusDir | Out-Null

    Remove-StaleAdoptionLinks -StatusDir $statusDir

    # Scan both status AND port files (real, non-link) - a crashed prior
    # instance leaves both behind under the same port-derived names, so a
    # collision with a re-adopted candidate can land on either one (review
    # round 3 blocking fix). Test-StatusFileLive only ever returns $true for
    # a status file (a port file's JSON has no last_heartbeat field, so it
    # always reads as "not live") - a real port file can therefore never
    # cause a false early-return here, only ever end up correctly classified
    # as stale below.
    $existingRealStatus = Get-ChildItem -LiteralPath $statusDir -Force -Filter 'unity-mcp-status-*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-EntryIsLink -Entry $_) }
    $existingRealPort = Get-ChildItem -LiteralPath $statusDir -Force -Filter 'unity-mcp-port-*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-EntryIsLink -Entry $_) }
    $existingReal = @($existingRealStatus) + @($existingRealPort)
    $staleReal = @()
    if ($existingReal) {
        $liveReal = $existingReal | Where-Object {
            Test-StatusFileLive -StatusFilePath $_.FullName -HeartbeatMaxAgeSeconds $HeartbeatMaxAgeSeconds -PortProbeTimeoutMs $PortProbeTimeoutMs
        }
        if ($liveReal) { return }
        # Every existing real file is stale (e.g. a crashed prior instance) -
        # do NOT let its mere presence block scanning for a Hub-started
        # editor (review round 1 blocking finding). Left in place UNLESS its
        # leaf name collides with the candidate adopted below (review round 3
        # blocking fix, see the comment at the removal site) - only symlink
        # entries are otherwise ever removed by this preamble
        # (Remove-StaleAdoptionLinks above); a non-colliding stale real file
        # is harmless once Get-UnityMcpLaunchDecision scans every status file
        # for liveness rather than trusting any one of them.
        $staleReal = $existingReal
    }

    $candidate = Find-AdoptionCandidate -CheckoutPath $CheckoutPath -GlobalStatusDir $GlobalStatusDir -HeartbeatMaxAgeSeconds $HeartbeatMaxAgeSeconds -PortProbeTimeoutMs $PortProbeTimeoutMs
    if (-not $candidate) { return }

    $statusLink = Join-Path $statusDir (Split-Path -Leaf $candidate.StatusFile)
    $portLink   = Join-Path $statusDir (Split-Path -Leaf $candidate.PortFile)

    # Collision guard (review round 3 blocking fix): a stale real file already
    # proven stale above may happen to share its leaf name with the adoption
    # candidate's target filename - filenames are port-derived and a crashed
    # instance's port can be reused. New-AdoptionSymlink refuses
    # unconditionally on ANY real (non-link) file at its destination, so
    # leaving a proven-stale collider in place would wedge adoption (and the
    # fallback launch, since Invoke-UnityMcpLauncherFlow always adopts first)
    # with no automatic recovery. Remove exactly the colliding stale file(s) -
    # never every stale file - so a non-colliding one still survives untouched
    # (the round 1 invariant, asserted by the sibling Describe above).
    foreach ($linkPath in @($statusLink, $portLink)) {
        $collision = $staleReal | Where-Object { $_.FullName -eq $linkPath }
        if ($collision) {
            Remove-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
        }
    }

    try {
        New-AdoptionSymlink -LinkPath $statusLink -Target $candidate.StatusFile
        New-AdoptionSymlink -LinkPath $portLink   -Target $candidate.PortFile
    } catch {
        # The Developer-Mode/Administrator remedy only applies to a genuine
        # permission/access-denied failure. New-AdoptionSymlink can also throw
        # its own "a real (non-symlink) file already exists" error for a
        # reason the collision guard above didn't catch - e.g. a real file
        # created at $statusLink/$portLink in the race window between the
        # $existingReal scan (which covers both status and port files - see
        # above) and this call - attaching the Developer-Mode remedy to THAT
        # cause is nonsensical and misleads whoever reads the error (review
        # round 3 nit).
        $isPermissionError = ($_.Exception -is [System.UnauthorizedAccessException]) -or
            ($_.Exception.Message -match '(?i)access is denied|administrator privilege|privilege is required|permission denied')
        if ($isPermissionError) {
            throw "Failed to symlink an adopted Unity Hub instance into '$statusDir': $($_.Exception.Message). Creating a symbolic link on Windows requires Developer Mode (Settings > Update & Security > For developers > Developer Mode) or Administrator privileges - enable one of these and retry."
        }
        throw "Failed to symlink an adopted Unity Hub instance into '$statusDir': $($_.Exception.Message)"
    }
    Write-Host "Adopted a Hub-started Unity editor for this checkout -> $statusDir"
}

function Get-UnityMcpLaunchDecision {
    # 'already-connected' when a live status file (real or a freshly-adopted
    # link) passes the same heartbeat/port checks; otherwise 'launch'. By the
    # time this runs the preamble has already deleted dangling/stale links,
    # so "dangling" and "nothing present" are the same input here.
    param(
        [Parameter(Mandatory)][string]$StatusDir,
        [int]$HeartbeatMaxAgeSeconds = $HeartbeatMaxAgeSeconds,
        [int]$PortProbeTimeoutMs = $PortProbeTimeoutMs
    )
    if (-not (Test-Path -LiteralPath $StatusDir)) { return 'launch' }
    $statusFiles = Get-ChildItem -LiteralPath $StatusDir -Force -Filter 'unity-mcp-status-*.json' -ErrorAction SilentlyContinue
    foreach ($sf in $statusFiles) {
        if (Test-StatusFileLive -StatusFilePath $sf.FullName -HeartbeatMaxAgeSeconds $HeartbeatMaxAgeSeconds -PortProbeTimeoutMs $PortProbeTimeoutMs) {
            return 'already-connected'
        }
    }
    return 'launch'
}

function Test-ShouldSkipLibraryMirror {
    # Ticket #47 / Finding stays fixed: the pre-existing IsNullOrEmpty/Test-Path
    # guard cannot detect $mainRoot -eq $proj (the resolved path DOES exist -
    # it IS the checkout itself, when run from the main checkout), so a
    # same-path guard is required in addition to that guard.
    param(
        [Parameter(Mandatory)][string]$mainRoot,
        [Parameter(Mandatory)][string]$proj
    )
    $mainRoot = $mainRoot.TrimEnd('\', '/')
    $proj     = $proj.TrimEnd('\', '/')
    return ($mainRoot -eq $proj)
}

function Invoke-LibraryRobocopy {
    # The actual robocopy/rsync call, extracted so it is mockable. Real source
    # existence is re-checked here (not in Invoke-LibraryMirror) so a mocked
    # call in tests always fires regardless of fixture contents.
    param(
        [Parameter(Mandatory)][string]$SourceLib,
        [Parameter(Mandatory)][string]$DestLib
    )
    if (-not (Test-Path -LiteralPath $SourceLib)) {
        Write-Host "UNITY_WORKTREE_MIRROR_LIBRARY=1: no Library/ found in main checkout ($SourceLib) - skipping"
        return
    }
    if ($script:OnWindows) {
        robocopy $SourceLib $DestLib /MIR /MT:16
        if ($LASTEXITCODE -gt 7) { throw "robocopy Library mirror failed (exit $LASTEXITCODE)" }
    } else {
        & rsync -a --delete "$SourceLib/" "$DestLib/"
        if ($LASTEXITCODE -ne 0) { throw "rsync Library mirror failed (exit $LASTEXITCODE)" }
    }
}

function Invoke-LibraryMirror {
    param(
        [Parameter(Mandatory)][string]$MainRoot,
        [Parameter(Mandatory)][string]$Proj
    )
    if (Test-ShouldSkipLibraryMirror -MainRoot $MainRoot -Proj $Proj) {
        Write-Host "UNITY_WORKTREE_MIRROR_LIBRARY=1: could not resolve a distinct main checkout (running from main checkout?) - skipping Library mirror"
        return
    }
    $srcLib = Join-Path $MainRoot 'Library'
    $dstLib = Join-Path $Proj 'Library'
    Write-Host "UNITY_WORKTREE_MIRROR_LIBRARY=1: mirroring Library from $srcLib -> $dstLib"
    Invoke-LibraryRobocopy -SourceLib $srcLib -DestLib $dstLib
    Write-Host "UNITY_WORKTREE_MIRROR_LIBRARY=1: Library mirror complete"
}

function Start-UnityEditor {
    # The actual Unity launch: editor resolution, cache server, Library
    # mirror, UNITY_MCP_STATUS_DIR env, pid file - moved here unchanged from
    # the old per-variant inline $managedBlock body (ticket #47). -batchmode
    # -nographics and the two "launched ..." messages are the only $Variant
    # branches; everything else exists once.
    param(
        [Parameter(Mandatory)][ValidateSet('default', 'gui')][string]$Variant,
        [Parameter(Mandatory)][string]$CheckoutPath,
        [Parameter(Mandatory)][string]$StatusDir
    )
    $proj = $CheckoutPath
    New-Item -ItemType Directory -Force -Path $StatusDir | Out-Null

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
        if ($script:OnWindows) { $editor = "C:/Program Files/Unity/Hub/Editor/$ver/Editor/Unity.exe" }
        elseif ($IsMacOS)      { $editor = "/Applications/Unity/Hub/Editor/$ver/Unity.app/Contents/MacOS/Unity" }
        else                   { $editor = "$HOME/Unity/Hub/Editor/$ver/Editor/Unity" }
    }
    if (-not (Test-Path $editor)) {
        throw "Unity Editor not found at '$editor' - set UNITY_EDITOR_PATH to your editor binary"
    }

    # Status-dir isolation: both the editor bridge and the session MCP server must
    # point at this exact ABSOLUTE dir so the server discovers exactly one instance
    # and auto-connects with no UI step.
    $env:UNITY_MCP_STATUS_DIR = $StatusDir
    $env:UNITY_MCP_ALLOW_BATCH = '1'
    $log = Join-Path $StatusDir 'editor.log'
    $unityArgs = @(
        '-logFile', $log,
        '-projectPath', $proj,
        '-executeMethod', 'MCPForUnity.Editor.McpCiBoot.StartStdioForCi'
    )
    if ($Variant -eq 'default') {
        $unityArgs = @('-batchmode', '-nographics') + $unityArgs
    }
    # GUI mode: UNITY_MCP_ALLOW_BATCH=1 does not suppress EditorUtility.DisplayDialog;
    # use the default (headless) variant for unattended automation.

    if ($env:UNITY_WORKTREE_MIRROR_LIBRARY -eq '1') {
        $gitCommonDir = (& git rev-parse --git-common-dir 2>$null)
        if ($LASTEXITCODE -eq 0 -and $gitCommonDir) {
            $gitCommonDirAbs = Convert-Path -LiteralPath $gitCommonDir.Trim() -ErrorAction SilentlyContinue
            $mainRoot = if ($gitCommonDirAbs) { Split-Path -Parent $gitCommonDirAbs } else { $null }
            if ([string]::IsNullOrEmpty($mainRoot) -or -not (Test-Path $mainRoot)) {
                Write-Host "UNITY_WORKTREE_MIRROR_LIBRARY=1: could not resolve a distinct main checkout (running from main checkout?) - skipping Library mirror"
            } else {
                $lockfile = Join-Path $mainRoot 'Temp/UnityLockfile'
                if (Test-Path $lockfile) {
                    Write-Host "UNITY_WORKTREE_MIRROR_LIBRARY=1: main checkout Unity is running (lockfile present) - skipping Library mirror"
                } else {
                    Invoke-LibraryMirror -MainRoot $mainRoot -Proj $proj
                }
            }
        } else {
            Write-Host "UNITY_WORKTREE_MIRROR_LIBRARY=1: could not resolve main checkout via git rev-parse - skipping Library mirror"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:UNITY_WORKTREE_CACHE_SERVER)) {
        $unityArgs += @('-EnableCacheServer', '-cacheServerEndpoint', $env:UNITY_WORKTREE_CACHE_SERVER)
        Write-Host "UNITY_WORKTREE_CACHE_SERVER=$($env:UNITY_WORKTREE_CACHE_SERVER): enabling asset cache server"
    }
    if ([string]::IsNullOrWhiteSpace($env:UNITY_WORKTREE_CACHE_SERVER) -and $env:UNITY_WORKTREE_MIRROR_LIBRARY -ne '1') { Write-Host "COLD START: No acceleration active. Cold import on an asset-heavy project can take 5-65 min. Set UNITY_WORKTREE_CACHE_SERVER=<host:port> (fastest) or UNITY_WORKTREE_MIRROR_LIBRARY=1 (no server needed). On Windows, add the worktree-store root and Unity install path to Windows Defender exclusions to halve scan overhead." }

    $p = Start-Process -FilePath $editor -ArgumentList $unityArgs -PassThru
    Set-Content -Path (Join-Path $StatusDir 'unity.pid') -Value $p.Id
    if ($Variant -eq 'default') {
        Write-Host "Unity bridge launched headless (pid $($p.Id)) -> $StatusDir"
    } else {
        Write-Host "Unity bridge launched with visible editor (pid $($p.Id)) -> $StatusDir"
    }
}

function Invoke-UnityMcpLauncherFlow {
    # Full launch flow (both the managed start: steps and a bare invocation
    # without -AdoptOnly use this): adopt, decide, and launch only if needed.
    # -Variant is declared explicitly (review round 1 nit) rather than relying
    # on implicit PowerShell scope chaining up to the top-level param() block.
    param(
        [Parameter(Mandatory)][string]$CheckoutPath,
        [Parameter(Mandatory)][string]$GlobalStatusDir,
        [ValidateSet('default', 'gui')][string]$Variant = 'default'
    )
    Invoke-UnityMcpAdoption -CheckoutPath $CheckoutPath -GlobalStatusDir $GlobalStatusDir
    $statusDir = Join-Path $CheckoutPath '.unity-mcp'
    $decision = Get-UnityMcpLaunchDecision -StatusDir $statusDir
    if ($decision -eq 'already-connected') {
        $realFile = Get-ChildItem -LiteralPath $statusDir -Force -Filter 'unity-mcp-status-*.json' -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-EntryIsLink -Entry $_) } |
            Select-Object -First 1
        if ($realFile) {
            Write-Host "Unity bridge already running for this checkout (this session's own prior instance) -> $statusDir"
        } else {
            Write-Host "Already connected to an adopted Unity Hub instance for this checkout -> $statusDir"
        }
        return
    }
    Start-UnityEditor -Variant $Variant -CheckoutPath $CheckoutPath -StatusDir $statusDir
}

# Entry point - only runs on a real invocation (`&` / direct execution), never
# when dot-sourced (". path") purely to load the functions above for testing
# or mocking; $MyInvocation.InvocationName is '.' in that case.
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $CheckoutPath) {
        throw "unity-mcp-launch.ps1: -CheckoutPath is required"
    }
    # Canonicalize before use: a caller invoking this manually with a relative
    # path (e.g. -CheckoutPath .) must still get the plan's "UNITY_MCP_STATUS_DIR
    # is absolute in both cases" guarantee. [System.IO.Path]::GetFullPath is
    # deliberately NOT used here: it resolves against .NET's process-wide
    # [Environment]::CurrentDirectory, which PowerShell 7+'s Set-Location does
    # NOT keep in sync with $PWD (verified empirically - GetFullPath('leaf')
    # after Set-Location into a different directory still resolved against the
    # process's original directory, not $PWD). Resolve-Path IS PowerShell
    # provider-aware and tracks $PWD correctly, but throws when the path
    # doesn't exist yet - so it's used only when the path already exists;
    # otherwise fall back to joining against the current PowerShell location
    # (Get-Location, not GetFullPath) so a not-yet-created checkout still
    # canonicalizes correctly. An already-absolute path is left untouched
    # (Join-Path would otherwise mangle a rooted child path - verified
    # empirically: Join-Path 'C:\a' 'D:\b' -> 'C:\a\D:\b', not 'D:\b').
    if (-not [System.IO.Path]::IsPathRooted($CheckoutPath)) {
        if (Test-Path -LiteralPath $CheckoutPath) {
            $CheckoutPath = (Resolve-Path -LiteralPath $CheckoutPath).Path
        } else {
            $CheckoutPath = Join-Path -Path (Get-Location).Path -ChildPath $CheckoutPath
        }
    }
    if ($AdoptOnly) {
        Invoke-UnityMcpAdoption -CheckoutPath $CheckoutPath -GlobalStatusDir $GlobalStatusDir
    } else {
        Invoke-UnityMcpLauncherFlow -CheckoutPath $CheckoutPath -GlobalStatusDir $GlobalStatusDir -Variant $Variant
    }
}
# <<< agent-unity-wrapper generated
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
    # The file already exists. Existence, not content, is the sole ownership rule
    # (ticket #37): no append, no isolation flip, no reconcile, under any flag. Ticket
    # #39 carries this the rest of the way - the script does not read the file at all,
    # so it cannot classify it as missing/foreign/outdated, and it never comments on
    # `isolation` or any other field. Test-Path above is the only permitted check.
    Write-Info ".seretos/worktree-setup.yml exists - leaving it untouched."
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

# --- 4. .seretos/unity-mcp-launch.ps1 (ticket #47 - always regenerated) -----
# Unlike .seretos/worktree-setup.yml above, this file is owned outright by
# this plugin: it is written on every run, with no -Force gate and no
# existence check, so an update to the launch/adoption logic reaches every
# already-prepared repo the next time this script runs. Never added to
# .gitignore - it is tracked repo content, matching $managedBlock's model.
$launchScriptPath = Join-Path $RepoRoot '.seretos/unity-mcp-launch.ps1'
Write-Utf8NoBom -Path $launchScriptPath -Content $launchScript
Write-Info "Wrote .seretos/unity-mcp-launch.ps1 (always regenerated)."

Write-Info "Done. Review and commit the changes, then environment_start will boot Unity per environment (linked worktree, or the main checkout via checkout_path)."
