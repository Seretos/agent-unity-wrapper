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
   bridge socket automatically. Never add an env-specific project path to the manifest —
   it would break the plugin for every other user.
