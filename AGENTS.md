# agent-unity-wrapper

Pure skill plugin — no binary of its own. It wraps the **external Unity MCP server**: a skill teaches Claude how to drive it, and (once wired) the manifests point at that MCP. This repo ships **only** the skill + manifests; the Unity MCP itself is a separate, pre-existing server.

> **Wired.** The Unity MCP (`mcpforunityserver==9.7.1`) is now wired into both manifests under the server key `unityMCP`. The scaffold state is resolved: `mcpServers` is present inline in both `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json`, and `skills/unity-wrapper/SKILL.md` contains the full tool inventory and usage docs.

## Contracts an agent won't infer from the tree

- **The wrapped MCP is external and inline, not a `.mcp.json`.** When wired, the MCP command goes into an inline `mcpServers` block in **both** `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json` (the two hosts can't share one external file — `${CLAUDE_PLUGIN_ROOT}` doesn't expand under Codex). Model it on `agent-serena-wrapper`, whose Claude manifest uses `--context claude-code` + `${CLAUDE_PROJECT_DIR}` and whose Codex manifest uses `--context codex` + `--project-from-cwd`.
- **Release is orphan-branch + marketplace dispatch.** `release.yml` (manual: Actions → release → `version=X.Y.Z`) stamps the version into both manifests, force-pushes an orphan `release` branch holding only install-ready files, and POSTs a dispatch (`category: skill`) to `Seretos/agent-marketplace`. `main` and `release` share no history. Clients install at the tag `agent-unity-wrapper--vX.Y.Z`.
- **Required secret:** `MARKETPLACE_DISPATCH_TOKEN` — fine-grained PAT, `Contents: RW` + `Pull requests: RW` on `Seretos/agent-marketplace` only.
- **`assets/icon.png` and `description.md` are release artifacts, not just repo files.** The dispatch payload sends `raw.githubusercontent.com/${repo}/${TAG}/assets/icon.png` and `.../description.md` URLs to the marketplace, so both must live on the orphan `release` branch at the tagged commit — `release.yml`'s stage step copies them into the staging tree. Ship a real icon and a filled-in `description.md` before cutting v0.0.1 or the listing has no image / placeholder text.
