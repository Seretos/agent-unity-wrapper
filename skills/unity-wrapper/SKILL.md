---
name: unity-wrapper
description: Drive the Unity editor through the external Unity MCP server — inspect and modify scenes, GameObjects, components, and assets via structured operations instead of guessing project state. Use when working inside a Unity project, exploring its scene graph, or making editor changes.
---

# unity-wrapper

## What this skill is for

Reach for this skill when the task involves a **Unity project** — exploring its scene
graph, locating or editing GameObjects and components, or inspecting assets. The skill
routes that work through the Unity MCP server's structured tools rather than reading or
guessing at serialized scene/asset files.

## Mental model

The Unity MCP has two halves that must both be running for any tool call to succeed:

1. **Python MCP server** (`mcpforunityserver==9.7.1`, launched via `uvx`) — this is the
   process the MCP host (Claude Code / Codex) connects to over `stdio`. It translates
   MCP tool calls into messages sent to the Unity editor.

2. **C# bridge package** — a Unity package (`MCP For Unity`, installed from the
   `CoplayDev/unity-mcp` git URL) that runs inside the target Unity project. It opens a
   local socket and listens for commands from the Python server. Without it loaded in the
   editor, the Python server has nothing to connect to and all calls fail.

The flow is: **MCP host → Python server (stdio) → local socket → C# bridge → Unity editor**.

Key entities the MCP exposes:

- **Scenes** — the currently open scene(s) in the editor; operations read/write their
  serialized state live (unsaved changes are visible immediately but not persisted until
  saved).
- **GameObjects** — named nodes in the scene hierarchy, each carrying an active state,
  transform, tag, and layer.
- **Components** — MonoBehaviour and built-in components attached to GameObjects; fields
  are readable and writable by name.
- **Assets** — files under `Assets/` (scripts, prefabs, materials, textures, etc.);
  listable and queryable by path or type.
- **Edit / Play mode lifecycle** — the editor starts in Edit mode; entering Play mode
  runs the game loop. Some tools behave differently or are unavailable during Play mode.

## Tool inventory

The tools below are exposed by the Unity MCP server (MCP server key: `unityMCP`).
Tool names are the capability areas; the exact MCP method identifiers are defined by
the upstream `CoplayDev/unity-mcp` server.

| Tool / Area | What it is best for |
|---|---|
| **Scene inspection** | List open scenes, get the full GameObject hierarchy, query scene metadata (name, path, dirty state) |
| **GameObject queries** | Find GameObjects by name, tag, or path; get a GameObject's children, active state, transform, and component list |
| **Component read** | Read all field values on a named component attached to a specific GameObject |
| **Component write** | Set one or more fields on a named component (e.g. change a `Transform.position`, toggle a flag) |
| **Asset listing** | List files under `Assets/` filtered by folder or type; useful for locating scripts, prefabs, and materials |
| **Asset inspection** | Read metadata and serialized content of a specific asset by its project-relative path |
| **Play-mode control** | Enter Play mode, exit Play mode, query the current editor mode |
| **Script / console access** | Execute editor scripts or retrieve Unity console log output (errors, warnings, info) |

## Patterns and recipes

### Inspect the scene hierarchy

1. Use the **scene inspection** tool to list open scenes and confirm which scene is active.
2. Use the **scene inspection** / **GameObject queries** tool to retrieve the root
   GameObjects and recursively expand the hierarchy to the depth you need.
3. Use **GameObject queries** (find by name/tag) when you know what you are looking for
   rather than walking the whole tree.

### Read a component value on a specific GameObject

1. Use **GameObject queries** (find by name or path) to confirm the target GameObject
   exists and to get its component list.
2. Use **component read** with the GameObject path and component type name to retrieve
   all field values.
3. Inspect the returned fields — field names match Unity's serialized property names
   (e.g. `m_LocalPosition` for a Transform).

### Modify a component field

1. Confirm the target with **component read** first (see above) so you know current
   values and correct field names.
2. Use **component write** supplying the GameObject path, component type, and a dict of
   `{fieldName: newValue}`.
3. Re-read with **component read** to verify the change took effect.
4. Save the scene explicitly (via the editor or a save-scene tool call) if the change
   must survive a crash or reload.

### List and inspect project assets

1. Use **asset listing** to enumerate files under a specific folder (e.g. `Assets/Scripts`)
   or filtered by extension/type.
2. Use **asset inspection** with the returned project-relative path to read a specific
   asset's content or metadata.

### Enter and exit Play mode

1. Use **play-mode control** to query the current editor mode — confirm you are in Edit
   mode before entering.
2. Use **play-mode control** to enter Play mode and wait for confirmation that the
   editor has transitioned.
3. Perform any play-mode-specific queries (e.g. reading runtime component values).
4. Use **play-mode control** to exit Play mode before making any scene edits.

## Per-worktree Unity instances (worktree gate)

When the session runs inside a **git worktree** (via `agent-worktree`), each worktree
needs its **own** Unity Editor instance, and this session's MCP server must bind to
*that* instance with no manual "select instance" UI step. This is achieved with
**status-dir isolation** — no runtime routing logic in the skill.

### Status-dir isolation contract

Both halves of the Unity MCP point at the **same, worktree-local** status directory via
`UNITY_MCP_STATUS_DIR`:

- **MCP server side** — already wired in the manifests' `unityMCP.env`:
  - Claude: `UNITY_MCP_STATUS_DIR=${CLAUDE_PROJECT_DIR}/.unity-mcp` (absolute).
  - Codex: `UNITY_MCP_STATUS_DIR=.unity-mcp` (relative; the server resolves it against
    its working directory, which Codex sets to the project/worktree root).
- **Unity editor side** — the `start` step (below) launches Unity with the **absolute**
  `<worktree>/.unity-mcp`.

Both the Unity C# bridge and the Python server use this value **literally** (no `~`
expansion, no relative-path rewriting on the Unity side), so the editor launch must pass
an **absolute** path. When both sides resolve to the same directory, the server discovers
**exactly one** instance and auto-connects.

### When to boot (opt-in)

Preparing the worktree (running the prepare-script and committing the result) does **not**
require booting Unity. The decision point is whether the ticket actually needs the Unity
editor at all:

- **Editor-touching tickets** (scene edits, component changes, Play-mode testing, asset
  inspection): run `worktree_start` to execute the `start:` block and boot Unity, then
  proceed with MCP tool calls.
- **Backend / non-editor tickets** (pure C# logic, server code, CI config, etc.): skip
  `worktree_start` entirely — zero Unity processes, zero resource cost.

`worktree_stop` tears Unity down cleanly and is safe to call even if Unity was never
started — the stop script is guarded by a pid-file existence check and exits silently when
the pid file is absent.

### The gate — when config is missing, run the prepare-script

When working in a worktree on a Unity project and the per-worktree Unity config is missing
or incomplete — i.e. `.seretos/worktree-setup.yml` has no `mcp-unity-bridge-*` block, or
`Packages/manifest.json` lacks `com.coplaydev.unity-mcp` — run the idempotent prepare-script
**once at repo level**, then commit:

```
pwsh -File ${CLAUDE_PLUGIN_ROOT}/scripts/prepare-unity-worktree.ps1
```

It detects existing config and only fills gaps (never clobbers a foreign `start:`/`stop:`
block; pass `-Force` to refresh the managed block or flip `isolation` to `full`). Because a
worktree is a checkout of the same repo, the tracked files it writes inherit to every future
worktree — so you prepare once, not per worktree. Requires PowerShell 7+ for the launched
start/stop steps.

### Launch flow

1. `worktree_start` (agent-worktree) runs the matching `start` step variant:
   - **`default`** (no variant arg, or `variant=default`): launches a **headless** Unity
     (`-batchmode -nographics -projectPath <worktree>`) — correct for CI and automated MCP
     tool calls.
   - **`gui`** (`variant=gui`): launches a **visible editor** (same flags minus `-batchmode`
     and `-nographics`) — for interactive editing, visual debugging, or Play-mode with
     graphics.
   Both variants set `UNITY_MCP_STATUS_DIR=<worktree>/.unity-mcp`,
   `UNITY_MCP_ALLOW_BATCH=1`, and
   `-executeMethod MCPForUnity.Editor.McpCiBoot.StartStdioForCi` to boot the in-editor
   bridge. The launched PID is recorded in `.unity-mcp/unity.pid`.
2. The bridge writes its status file into the worktree-local `.unity-mcp`; this session's
   MCP server (pointed at the same dir) discovers the one instance and auto-connects.
3. `worktree_stop` runs the `stop` step → kills the recorded Unity PID.

Set `UNITY_EDITOR_PATH` to your Unity Editor binary to override editor resolution; if unset,
the start step derives the version from `ProjectSettings/ProjectVersion.txt` and looks under
the Unity Hub default install path.

### GUI / interactive launch

By default `worktree_start` boots Unity **headless** (`-batchmode -nographics`), which is
the correct mode for CI and automated MCP tool calls. When you need a visible editor
(interactive editing, visual debugging, Play-mode with graphics), use the named `gui`
variant:

```
worktree_start worktree_id=<id> variant=gui
```

No environment variable is needed. The `gui` start step runs the same launch sequence as
`default` but omits `-batchmode` and `-nographics`, so a full visible editor window
appears. On Windows `Start-Process -PassThru` detaches the editor from the terminal, so
the worktree shell remains usable. Trade-off: a visible editor window is created and the
full editor UI loads, which costs more memory and startup time than headless mode.

> **Repos prepared before named-variant steps were introduced:** the managed block must
> contain both `name: default` and `name: gui` start steps. If your repo was prepared by
> an older version of the prepare-script (the block has only a single unnamed start step or
> still contains `UNITY_WORKTREE_GUI`), re-run the prepare-script **with `-Force`** to
> refresh the managed block, then commit the updated `.seretos/worktree-setup.yml`. A
> freshly-prepared repo already has both steps and needs no special action.

### Cache Server (faster cold starts)

On asset-heavy projects, `worktree_start` triggers a full asset re-import into the
worktree-local `Library/` on first open. This can take several minutes before the C#
bridge reports `ready`, and the cost is paid again for every new worktree. A Unity Cache
Server (legacy protocol) or Unity Accelerator (same wire protocol) caches compiled import
artefacts so subsequent worktrees pull from the cache instead of reimporting from scratch.

To opt in, set the environment variable **before** calling `worktree_start`:

```
$env:UNITY_WORKTREE_CACHE_SERVER = 'localhost:10080'   # PowerShell
# or
export UNITY_WORKTREE_CACHE_SERVER=localhost:10080      # bash / zsh
```

When the variable is set, the managed `start:` step appends the following flags to the
Unity invocation:

```
-EnableCacheServer -cacheServerEndpoint <host:port>
```

The value is passed verbatim as the endpoint — use `host:port` format (e.g.
`localhost:10080` for a local Accelerator on its default port, or `192.168.1.5:10080`
for a shared server on the network). When the variable is empty, whitespace-only, or
unset, no cache-server flags are injected.

**Sharing `Library/` via symlink is NOT the chosen approach.** Unity acquires an
exclusive `Library/UnityLockfile` so only one editor process can own a `Library/` at a
time. `Library/ArtifactDB` is a single-writer database that corrupts under concurrent
access. When two worktrees track different commits their import metadata diverges,
causing constant cache thrashing if they share a `Library/`. A Cache Server / Accelerator
avoids all three problems: each worktree keeps its own `Library/` but pulls already-built
artefacts from the shared cache over a network socket.

**Running the Cache Server or Accelerator is out of scope for this plugin.** Setting up
and launching a Unity Accelerator (or the legacy Unity Cache Server) on your machine or
CI host is a separate step — see
[Unity Accelerator docs](https://docs.unity3d.com/Manual/UnityAccelerator.html) and
[Cache Server docs](https://docs.unity3d.com/Manual/CacheServer.html) upstream.

> **Repos prepared before this feature was added:** the `UNITY_WORKTREE_CACHE_SERVER`
> conditional lives inside the managed block written by the prepare-script. If your repo
> was prepared by an older version of the script, the existing managed block does not
> contain the conditional, so setting `UNITY_WORKTREE_CACHE_SERVER` is silently inert.
> Re-run the prepare-script **with `-Force`** to refresh the managed block, then commit
> the updated `.seretos/worktree-setup.yml`. A freshly-prepared repo already has the
> conditional and needs no special action.

### Warm-start: Mirror Main Library

When a Unity Cache Server or Accelerator is not available, you can reduce cold-import
time by pre-populating a new worktree's `Library/` from the main checkout before
`worktree_start` opens Unity there. This is a lightweight, zero-infrastructure
alternative to the Cache Server path (see above and #7). It is best-effort only — Unity
may still reimport some or all assets depending on what has changed between the main
checkout and the worktree branch.

**Precondition: the main-checkout Unity Editor must not be running.** Unity holds an
exclusive lock on `Library/` while it is open. Check that the lockfile is absent before
copying:

```
# Confirm Unity is not running in the main checkout
ls <main-checkout>/Temp/UnityLockfile   # must NOT exist
```

(`Temp/UnityLockfile` is the project-open lock Unity writes while an editor instance
owns that project; it lives under `Temp/`, not `Library/`.)

If the lockfile is present, wait for the editor to close or stop it first (`worktree_stop`
if it was started by `agent-worktree`; otherwise close the editor window or kill the
process). Do not copy a `Library/` while Unity holds the lock — partial copies produce
corrupt import state.

**Copy the `Library/` into the worktree:**

```powershell
# Windows (PowerShell) — exit codes 0–7 are success for robocopy
# 0 = nothing to copy, 1 = files copied, 3 = files copied + extras deleted, 8+ = error
robocopy <main-checkout>\Library <worktree>\Library /MIR /MT:16
```

```bash
# POSIX (bash / zsh)
rsync -a --delete <main-checkout>/Library/ <worktree>/Library/
```

> **robocopy exit-code note:** robocopy uses non-standard exit codes. Exit code 1 means
> files were copied successfully (not an error). Exit codes 0–7 all indicate success;
> code 8 and above indicate a real error. If you are checking `$LASTEXITCODE` in
> PowerShell, treat any value ≤ 7 as success.

**Stale-lockfile trap (force-killed editor):** if a previous editor run in the
**worktree** was killed forcefully, it may have left a stale lockfile at
`<worktree>/Temp/UnityLockfile`. Unity refuses to open the project while this file
exists, logging `HandleProjectAlreadyOpenInAnotherInstance`. Delete it before calling
`worktree_start`:

```
Remove-Item <worktree>\Temp\UnityLockfile -ErrorAction SilentlyContinue  # PowerShell
# or
rm -f <worktree>/Temp/UnityLockfile                                       # bash / zsh
```

**Honest caveat — this is best-effort, not guaranteed.** Real-world outcomes vary
depending on how much has changed since the mirrored `Library/` was built:

- Case #81 (branch-only delta, same project path): mirroring eliminated the cold import
  entirely — Unity opened and the bridge reported `ready` without reimporting.
- Case #86 (new project path): `Library/ArtifactDB` was invalidated because the stored
  import metadata references the old absolute path; Unity performed a full reimport
  anyway.

Mirroring may help or may not, depending on how much has changed since the `Library/`
was built. When it works, it can save several minutes; when it does not, the only cost
is the time spent copying.

The robust primary flow is plain `worktree_start` (headless, no extra env vars required):
call `worktree_start` and poll until the bridge writes its status file into the
worktree-local `.unity-mcp/` directory. If a visible editor is needed (interactive
editing, visual debugging, Play-mode with graphics), use `worktree_start variant=gui` —
but GUI mode is an optional variant, not a requirement for reliable MCP usage. Mirroring
is an optional accelerator applied *before* `worktree_start`, not a replacement for the
documented launch flow.

For a durable, infrastructure-backed alternative that survives project-path changes and
branch switches, see the Cache Server section above.

## Pitfalls

1. **Unity-side bridge is a hard prerequisite.** The `MCP For Unity` C# package must be
   installed in the target Unity project (Package Manager → Add package by git URL:
   `https://github.com/CoplayDev/unity-mcp.git`) and the Unity editor must be **open
   and running** before any tool call is made. If the bridge is absent or the editor is
   closed, the Python server cannot connect and every call will error.

2. **Edit mode vs. Play mode.** Some tools (especially component writes and scene saves)
   behave differently or are outright unavailable while the editor is in Play mode.
   Always check the editor mode before performing structural edits; exit Play mode first
   if needed.

3. **Unsaved scene state.** The MCP reads and writes the live editor state. Changes made
   via component write or other mutation tools are visible immediately in the editor but
   are NOT saved to disk until an explicit save. If the editor crashes or the scene is
   reloaded without saving, those changes are lost. Always save explicitly after a
   meaningful batch of edits.

4. **No project-path flag in the manifest by design.** The manifest does not bake in a
   Unity project path. The Python server discovers the running Unity editor via the
   bridge socket automatically. Never add an env-specific *absolute* project path to the
   manifest — it would break the plugin for every other user. The one env the manifest
   *does* set, `UNITY_MCP_STATUS_DIR`, is intentional and host-portable
   (`${CLAUDE_PROJECT_DIR}/.unity-mcp` on Claude, cwd-relative `.unity-mcp` on Codex) — it
   enables per-worktree status-dir isolation (see "Per-worktree Unity instances"), not a
   hardcoded path.
