# agent-unity-wrapper

A Claude Code **skill** plugin. Pairs the external Unity MCP server with a skill so Claude can drive the Unity editor — inspecting scenes, GameObjects, and assets — through structured MCP operations instead of guessing project state.

This plugin ships **only the skill content** — no binaries of its own. It wraps a separate, pre-existing **Unity MCP server**.

> **Status:** scaffolded wrapper frame. The Unity MCP is not yet wired in (no `mcpServers` block yet); the skill is a stub. See `AGENTS.md` for what's pending.

## Install

```
/plugin marketplace add Seretos/agent-marketplace
/plugin install agent-unity-wrapper@agent-marketplace
```

## What the skill teaches

See `skills/unity-wrapper/SKILL.md` for the full content.
