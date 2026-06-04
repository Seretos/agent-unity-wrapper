---
name: unity-wrapper
description: Drive the Unity editor through the external Unity MCP server — inspect and modify scenes, GameObjects, components, and assets via structured operations instead of guessing project state. Use when working inside a Unity project, exploring its scene graph, or making editor changes.
---

# unity-wrapper

> **Scaffold stub.** The Unity MCP is not yet wired into this plugin's manifests, so the
> tool inventory below is intentionally a placeholder. Fill it in — and add the inline
> `mcpServers` block to both manifests — when connecting the real Unity MCP. Model the
> structure on `agent-serena-wrapper`'s `serena-wrapper` skill.

## What this skill is for

Reach for this skill when the task involves a **Unity project** — exploring its scene
graph, locating or editing GameObjects and components, or inspecting assets. The skill
routes that work through the Unity MCP server's structured tools rather than reading or
guessing at serialized scene/asset files.

## Mental model

(TODO once the MCP is wired) — the core entities the Unity MCP exposes (scenes,
GameObjects, components, assets, the play/edit-mode lifecycle) and how they relate.

## Tool inventory

(TODO once the MCP is wired) — list the Unity MCP tools and what each is good for.

## Patterns and recipes

(TODO once the MCP is wired) — concrete examples for common Unity requests.

## Pitfalls

(TODO once the MCP is wired) — edit-mode vs. play-mode, unsaved scene state, and other
gotchas to avoid.
