# agent-unity-wrapper

A Claude Code **skill** plugin. Pairs the external Unity MCP server with a skill so Claude can drive the Unity editor — inspecting scenes, GameObjects, and assets — through structured MCP operations instead of guessing project state. It also ships a second, MCP-free skill covering git-merging Unity's YAML-serialized assets.

This plugin ships **only skill content** — no binaries of its own. It wraps a separate, pre-existing **Unity MCP server**.

> **Status:** wired. The Unity MCP server is connected under the `unityMCP` server key, and both skills ship full content. See `AGENTS.md` for the contracts an agent won't infer from the tree.

## Install

```
/plugin marketplace add Seretos/agent-marketplace
/plugin install agent-unity-wrapper@agent-marketplace
```

## What the skills teach

- **`unity-wrapper`** — drives the Unity editor through the Unity MCP server: scenes, GameObjects, components, assets, Play mode, Test Runner, screenshots, and per-worktree Unity boot. See `skills/unity-wrapper/SKILL.md`.
- **`unity-yaml-merge`** — git-merging Unity's YAML-serialized assets through the `UnityYAMLMerge` (SmartMerge) driver: detecting conflicts that leave no markers, wiring the merge driver, unattended-safe flags, and mechanically resolving a conflict. See `skills/unity-yaml-merge/SKILL.md`.
