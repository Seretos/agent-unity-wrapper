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

> **Visual verification mandate.** For UI/scene tickets, capturing and inspecting a
> screenshot in Play mode is part of the definition of done — it is not optional. Compile
> success, zero wire-warnings, and a Codex correctness review verify code structure, not
> whether data-bindings render visible content, badges are positioned correctly, or
> progress bars update at runtime. See "Capture a screenshot for visual verification" below.

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

### Capture a screenshot for visual verification

For UI/scene tickets, capturing a screenshot in Play mode is part of the definition of done.
Compile success, zero wire-warnings, and static review verify code structure only — they do
not verify that data-bindings render visible content or that layout is correct at runtime.
Before marking a UI ticket done, capture a screenshot and inspect it visually.

**Prerequisites:** Unity must be running under `variant=gui` (not headless). In headless
mode (`-batchmode -nographics`), `ScreenCapture.CaptureScreenshot` produces no output and
the display subsystem is not initialized, so the RenderTexture path also produces a blank
image on headless configurations without a display subsystem. Boot with
`worktree_start variant=gui` before executing the recipe below.

**Recipe — execute via `execute_code`:**

````csharp
// Visual verification screenshot — execute in Play mode via the Unity MCP execute_code tool.
// Output path: <worktree>/.unity-mcp/screenshot.png
// Run AFTER entering Play mode and waiting for the scene to finish loading.

// 1. Resolve output path into the worktree-local status dir (always present when the bridge is up).
string statusDir = System.Environment.GetEnvironmentVariable("UNITY_MCP_STATUS_DIR");
if (string.IsNullOrEmpty(statusDir))
    statusDir = System.IO.Path.Combine(UnityEngine.Application.dataPath, "..", ".unity-mcp");
string outputPath = System.IO.Path.GetFullPath(System.IO.Path.Combine(statusDir, "screenshot.png"));

// 2. Capture via RenderTexture + ReadPixels. Requires GUI mode — see prerequisites above;
//    headless (-nographics) yields a blank image.
int width  = UnityEngine.Screen.width  > 0 ? UnityEngine.Screen.width  : 1920;
int height = UnityEngine.Screen.height > 0 ? UnityEngine.Screen.height : 1080;

UnityEngine.RenderTexture rt = new UnityEngine.RenderTexture(width, height, 24);
UnityEngine.Camera cam = UnityEngine.Camera.main ?? UnityEngine.Object.FindObjectOfType<UnityEngine.Camera>();
if (cam == null) throw new System.Exception("No camera found in scene.");

UnityEngine.RenderTexture prev = cam.targetTexture;
cam.targetTexture = rt;
cam.Render();

UnityEngine.RenderTexture.active = rt;
UnityEngine.Texture2D tex = new UnityEngine.Texture2D(width, height, UnityEngine.TextureFormat.RGB24, false);
tex.ReadPixels(new UnityEngine.Rect(0, 0, width, height), 0, 0);
tex.Apply();

// Restore state.
cam.targetTexture = prev;
UnityEngine.RenderTexture.active = null;
UnityEngine.Object.DestroyImmediate(rt);

// 3. Write PNG.
System.IO.File.WriteAllBytes(outputPath, tex.EncodeToPNG());
UnityEngine.Object.DestroyImmediate(tex);

UnityEngine.Debug.Log($"[VisualVerify] Screenshot saved: {outputPath}");
````

**Step-by-step workflow:**

1. Boot with `worktree_start variant=gui` (GUI mode is required — see prerequisite above).
2. Wait for `unity-mcp-status-*.json` to appear in `.unity-mcp/` (bridge ready signal).
3. Enter Play mode via play-mode control and wait for the transition to complete.
4. Allow the scene one or two frames to finish its startup sequence (if the project has a
   loading screen, wait for it to resolve — inspect a known UI element's active state via
   component read if you need to gate on scene readiness).
5. Execute the code block above via script / console access (`execute_code`).
6. Read the path from the Debug.Log console output (`[VisualVerify] Screenshot saved: ...`) and inspect the image at `<worktree>/.unity-mcp/screenshot.png`.
7. Exit Play mode before making any structural edits.

> **GUI mode — dismiss blocking dialogs first.** Because this recipe runs exclusively
> in GUI mode, blocking modal dialogs can hang in-flight MCP calls until a human
> dismisses them. Dismiss any open dialogs before executing the code block above.
> See "GUI / interactive launch" for the full warning.

**Output path convention:** `<worktree>/.unity-mcp/screenshot.png`. The `.unity-mcp/`
directory is always present when the bridge is up (it is the status dir), so no directory
creation step is needed. Overwriting a previous capture is intentional — rename if you
need to retain multiple captures.

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

> **Stale managed block.** If the managed block exists but was written by an older version
> of the prepare-script, it may be missing the `UNITY_WORKTREE_CACHE_SERVER` conditional,
> the `UNITY_WORKTREE_MIRROR_LIBRARY` conditional, or the `COLD START:` hint. In that
> state, setting those env vars is **silently inert** — the block ignores them. The
> prepare-script warns when it detects this. Re-run with `-Force` to refresh the managed
> block, then commit the updated `.seretos/worktree-setup.yml`. A freshly-prepared repo
> already has all conditionals and needs no special action.

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
2. The bridge writes its status file (`unity-mcp-status-*.json`) into the worktree-local
   `.unity-mcp/` status dir. The appearance of any `unity-mcp-status-*.json` file in
   that directory is the authoritative readiness signal — once it exists, the bridge is
   up. This session's MCP server (pointed at the same dir) discovers the one instance
   and auto-connects.
3. `worktree_stop` runs the `stop` step → kills the recorded Unity PID.

Set `UNITY_EDITOR_PATH` to your Unity Editor binary to override editor resolution; if unset,
the start step derives the version from `ProjectSettings/ProjectVersion.txt` and looks under
the Unity Hub default install path.

### Cold-start expectations & acceleration

On a fresh worktree with no `Library/` and no acceleration active, Unity must re-import
every asset from scratch. **Expected duration: 5–65 min on asset-heavy projects** — plan
accordingly before calling `worktree_start`.

To reduce or eliminate the cold-import cost, set one or both of the following environment
variables **before** calling `worktree_start`:

| Env var | What it does | When to use |
|---|---|---|
| `UNITY_WORKTREE_CACHE_SERVER=<host:port>` | Connects Unity to a Cache Server / Accelerator; already-built artefacts are served from the cache instead of reimporting | **Fastest** — requires a running server (see "Cache Server" section) |
| `UNITY_WORKTREE_MIRROR_LIBRARY=1` | Copies the main checkout's `Library/` into the worktree before opening Unity | **No server needed** — best-effort, see "Warm-start: Mirror Main Library" section |

When neither variable is set the managed start step emits a `COLD START:` warning so the
wait time is expected rather than a surprise.

> **Windows Defender exclusions.** On Windows, Defender's real-time scanning can roughly
> double the import time by scanning every asset file as Unity writes it. To halve the
> overhead, add the following paths to the Windows Defender exclusion list (Settings →
> Windows Security → Virus & threat protection → Exclusions):
>
> - **Worktree-store root** — the directory that holds all your agent worktrees.
> - **Unity install path** — the directory containing the Unity Editor binary (e.g.
>   `C:\Program Files\Unity\Hub\Editor\<version>`).
> - **Unity editor process** — the `Unity.exe` process.
>
> No PowerShell commands are provided here; add these exclusions manually through the
> Windows Security UI or your organisation's endpoint management tool.

> **Cross-drive caveat (Case #86).** If the worktree-store is on a different drive or
> path from the main checkout, `Library/ArtifactDB`'s stored absolute paths are
> invalidated and the Library mirror may still trigger a full reimport despite the copy.
> In that case prefer `UNITY_WORKTREE_CACHE_SERVER` (the Cache Server path is immune to
> project-path changes). See "Warm-start: Mirror Main Library" for the full Case #86
> details.

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

> **Warning — blocking modal dialogs in GUI mode.** In a visible editor (`variant=gui`),
> Unity can display blocking modal dialogs when the MCP triggers a save operation — for
> example "Scene(s) Have Been Modified", overwrite confirmations, or "Auto Save disabled".
> These modals halt Unity's main thread (which is also where the bridge runs), causing all
> in-flight MCP calls to hang until a human dismisses them. `UNITY_MCP_ALLOW_BATCH=1` is
> set by the managed block but does **not** suppress `EditorUtility.DisplayDialog` in GUI
> mode (it only affects Play-mode dialogs). For unattended automation, always use the
> `default` (headless) variant. See "Headless vs. GUI — automation workflow" below.

> **Repos prepared before named-variant steps were introduced:** the managed block must
> contain both `name: default` and `name: gui` start steps. If your repo was prepared by
> an older version of the prepare-script (the block has only a single unnamed start step or
> still contains `UNITY_WORKTREE_GUI`), re-run the prepare-script **with `-Force`** to
> refresh the managed block, then commit the updated `.seretos/worktree-setup.yml`. A
> freshly-prepared repo already has both steps and needs no special action.

### Headless vs. GUI — automation workflow

- **Headless is the correct mode for all automated and agent-driven phases.** In
  `-batchmode`, `EditorUtility.DisplayDialog` returns its default value immediately with
  no UI, so save operations complete without blocking. Automated MCP tool calls run
  without human intervention.
- **GUI mode is for human review only.** MCP-triggered save operations (scene saves,
  asset writes, etc.) can produce blocking modal dialogs that halt Unity's main thread and
  hang all in-flight MCP calls until a human dismisses the dialog.
- **Recommended workflow:** run headless for all automated or agent-driven phases →
  `worktree_stop` → relaunch with `variant=gui` for human review → `worktree_stop` the
  GUI instance before resuming automated work.
- The long-term fix (non-interactive bridge save APIs) is an upstream
  `CoplayDev/unity-mcp` concern and is tracked separately.

### Standalone build (build-only, not MCP-connected)

A standalone build is a **third mode** alongside headless MCP and GUI. Unlike
those two, it is **not** MCP-connected: the project's own build script (e.g.
`build.ps1`) launches Unity as a separate `-batchmode -quit` process that writes
the artifact and exits cleanly. It obeys the **same exclusive-lockfile rule** as
the other two modes.

**Lockfile rule.** Unity holds an exclusive lock on `Temp/UnityLockfile` per
project path. Only one editor process — headless MCP, GUI, **or** a standalone
build — can own a worktree at a time. A second process fails immediately, logging
`HandleProjectAlreadyOpenInAnotherInstance` ("Multiple Unity instances cannot
open the same project").

**Recipe — run a standalone build while a session is active:**

1. `worktree_stop` — terminate the running MCP or GUI session to release the
   lockfile.
2. Run your standalone build script (the separate `-batchmode -quit` process
   writes the artifact and exits, releasing the lock).
3. `worktree_start variant=gui` (or `default`) — bring the editor back up
   afterwards if you need to continue working.

> **Disambiguating the two lockfile-error cases:** the error
> `HandleProjectAlreadyOpenInAnotherInstance` appears in two distinct situations.
> Here it means an *active* session legitimately holds the lock — resolve it with
> `worktree_stop` as shown above. If the error appears after a force-killed
> editor with *no* active session, the cause is a *stale* `Temp/UnityLockfile`
> left behind — see the **"Stale-lockfile trap"** note below for that case.

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

> **Cross-drive advantage.** Unlike the Library mirror, the Cache Server path is immune
> to project-path and cross-drive changes — `Library/ArtifactDB` path invalidation does
> not affect cache-server imports. If the worktree-store is on a different drive from the
> main checkout, the Cache Server is the more reliable acceleration choice. See the
> cross-drive callout at the top of the "Warm-start: Mirror Main Library" section below.

> **Repos prepared before this feature was added:** the `UNITY_WORKTREE_CACHE_SERVER`
> conditional lives inside the managed block written by the prepare-script. If your repo
> was prepared by an older version of the script, the existing managed block does not
> contain the conditional, so setting `UNITY_WORKTREE_CACHE_SERVER` is silently inert.
> Re-run the prepare-script **with `-Force`** to refresh the managed block, then commit
> the updated `.seretos/worktree-setup.yml`. A freshly-prepared repo already has the
> conditional and needs no special action.

### Warm-start: Mirror Main Library

> **Cross-drive / cross-path caveat (Case #86).** `Library/ArtifactDB` stores absolute
> paths internally. If the worktree-store is on a different drive or at a different root
> path from the main checkout, those stored paths are invalidated and the mirror may still
> trigger a full reimport despite the copy — best-effort, can also work cross-drive
> (observed on Unity 2022.3.62f3), so measure rather than assume. When the worktree-store
> and main checkout are on different drives, prefer `UNITY_WORKTREE_CACHE_SERVER` (the
> Cache Server path is immune to project-path changes). See the "Cache Server (faster cold
> starts)" section above.

When a Unity Cache Server or Accelerator is not available, you can reduce cold-import
time by pre-populating a new worktree's `Library/` from the main checkout before
`worktree_start` opens Unity there. This is a lightweight, zero-infrastructure
alternative to the Cache Server path (see above and #7). It is best-effort only — Unity
may still reimport some or all assets depending on what has changed between the main
checkout and the worktree branch.

**To activate it, set `UNITY_WORKTREE_MIRROR_LIBRARY` to `'1'` before calling `worktree_start`:**

```powershell
$env:UNITY_WORKTREE_MIRROR_LIBRARY = '1'
```

Then call the `worktree_start` MCP tool (with optional `variant=gui` for a visible editor).
After `worktree_start` returns, clear the variable if you do not want subsequent starts to mirror:

```powershell
Remove-Item Env:UNITY_WORKTREE_MIRROR_LIBRARY -ErrorAction SilentlyContinue
```

The managed `start:` block written by `prepare-unity-worktree.ps1` checks this env var
automatically. When set to `1`, it:

1. Resolves the main checkout root via `git rev-parse --git-common-dir` (works from
   inside any worktree without baking in an absolute path).
2. Checks `<main-checkout>/Temp/UnityLockfile` — if the lockfile is present the mirror is
   skipped with a log message and Unity starts normally (no throw). Do not mirror while
   the main-checkout editor is running; partial copies produce corrupt import state.
3. Copies `<main-checkout>/Library/` into the worktree's `Library/` using
   `robocopy /MIR /MT:16` on Windows or `rsync -a --delete` on POSIX.
4. Proceeds to launch the Unity Editor as usual.

If `UNITY_WORKTREE_MIRROR_LIBRARY` is unset or empty the step is skipped entirely — no
change in behaviour for repos that do not opt in.

> **robocopy exit-code note:** robocopy uses non-standard exit codes. Exit code 1 means
> files were copied successfully (not an error). Exit codes 0–7 all indicate success;
> code 8 and above indicate a real error. The managed step treats any exit code ≤ 7 as
> success and throws on 8 or above.

**Stale-lockfile trap (force-killed editor):** if a previous editor run in the
**worktree** was killed forcefully, it may have left a stale lockfile at
`<worktree>/Temp/UnityLockfile`. Unity refuses to open the project while this file
exists, logging `HandleProjectAlreadyOpenInAnotherInstance`. The managed `start:` block
does not automatically clear the worktree lockfile — remove it manually before calling
`worktree_start` if the previous run was force-killed.

**Honest caveat — this is best-effort, not guaranteed.** Real-world outcomes vary
depending on how much has changed since the mirrored `Library/` was built:

- Case #81 (branch-only delta, same project path): mirroring eliminated the cold import
  entirely — Unity opened and the bridge reported `ready` without reimporting.
- Case #86 (new project path / cross-drive): see the cross-drive callout at the top of
  this section — measure rather than assume, and prefer Cache Server when drives differ.

Mirroring may help or may not, depending on how much has changed since the `Library/`
was built. When it works, it can save several minutes; when it does not, the only cost
is the time spent copying.

The robust primary flow is plain `worktree_start` (headless, no extra env vars required):
call `worktree_start` and poll until a `unity-mcp-status-*.json` file appears in the
worktree-local `.unity-mcp/` directory — this is the authoritative readiness signal,
preferred over parsing `editor.log` for the `StartStdioForCi` banner. If a visible
editor is needed (interactive editing, visual debugging, Play-mode with graphics), use
`worktree_start variant=gui` — but GUI mode is an optional variant, not a requirement
for reliable MCP usage. Mirroring is an optional accelerator applied *before*
`worktree_start` (by the managed start step), not a replacement for the documented launch
flow.

> **Repos prepared before this feature was added:** the `UNITY_WORKTREE_MIRROR_LIBRARY`
> conditional lives inside the managed block written by the prepare-script. If your repo
> was prepared by an older version of the script, the existing managed block does not
> contain the conditional, so setting `UNITY_WORKTREE_MIRROR_LIBRARY=1` is silently
> inert. Re-run the prepare-script **with `-Force`** to refresh the managed block, then
> commit the updated `.seretos/worktree-setup.yml`. A freshly-prepared repo already has
> the conditional and needs no special action.

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

5. **Raw `Unity.exe` start is invisible to this session's MCP server.** Launching the
   editor directly does not set `UNITY_MCP_STATUS_DIR`, so the bridge writes its status
   file into the global `~/.unity-mcp` instead of the worktree-local `.unity-mcp`. This
   session's MCP server finds no instance and all tool calls fail silently. Always start
   via `worktree_start`.

6. **Test Runner can freeze the editor — use screenshot-based verification instead.**
   On some Unity projects the Test Runner triggers a SQLite flush or a domain reload that
   hangs the editor process. If `run_tests` freezes or the editor becomes unresponsive
   during a test run, do not retry it: kill the Unity process, remove the stale
   `<worktree>/Temp/UnityLockfile`, and restart with `worktree_start`. A cold-start
   Library re-import takes roughly 5–65 min depending on project size (see "Cold-start
   expectations & acceleration"). For UI/scene tickets, replace the `run_tests` step with
   the screenshot-capture recipe above — compile success + zero wire-warnings + a visual
   inspection of the screenshot is a sufficient definition of done.
