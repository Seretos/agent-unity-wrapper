# Upstream issue (ready to file): `port_discovery.list_candidate_files` throws on a dangling symlink

**Target repo:** `CoplayDev/unity-mcp` (the vendored `mcpforunityserver` Python package this
plugin wraps; server key `unityMCP`, currently pinned `mcpforunityserver==9.7.1`).

**Component:** `port_discovery.py`, function `list_candidate_files` (the routine that scans
a status directory for `unity-mcp-status-*.json` / `unity-mcp-port-*.json` candidates and
`stat()`s each one to read its metadata).

## Summary

`list_candidate_files` calls `Path.stat()` (or the equivalent `os.stat()`) on every file it
enumerates in the status directory, with no guard for a directory entry that exists but
whose target no longer does. A symlink whose target has been deleted enumerates normally
(the directory entry is still there) but raises `FileNotFoundError` the moment anything
`stat()`s it, because `stat()` follows the link. The scan aborts with an unhandled
`FileNotFoundError` instead of skipping the dead entry and continuing.

## Repro

1. Create a symlink inside the status directory pointing at a real
   `unity-mcp-status-*.json` (or `unity-mcp-port-*.json`) file.
2. Delete the symlink's target, leaving the (now dangling) symlink in place.
3. Trigger instance discovery (any MCP tool call, or whatever internally invokes
   `list_candidate_files` against that directory).
4. Observe `FileNotFoundError` propagating out of the `stat()` call instead of the scan
   simply skipping the dangling entry.

This is not a contrived scenario: `agent-unity-wrapper`'s ticket #47 Unity Hub-adoption
feature symlinks a Hub-started editor's status/port files into a checkout-local
`.unity-mcp/` directory so a session's MCP server discovers it automatically. If the
adopted Hub instance exits between the symlink being created and the next discovery scan,
the target file it pointed at may be gone (or replaced) before the dangling link is
cleaned up, producing exactly this shape of stale symlink.

## Suggested fix

Wrap the per-candidate `stat()` call in a narrow `try/except FileNotFoundError: continue`
(or equivalent) so one dangling entry is skipped rather than aborting the whole scan:

```python
for candidate in status_dir.glob("unity-mcp-status-*.json"):
    try:
        info = candidate.stat()
    except FileNotFoundError:
        # Dangling symlink (target deleted) or a file removed mid-scan - skip it,
        # do not abort discovery for every other candidate in the directory.
        continue
    # ... existing per-candidate handling using `info` ...
```

The same guard should apply to the parallel `unity-mcp-port-*.json` scan, and to any other
`stat()`/`open()` call in the same discovery path that assumes a listed directory entry is
still resolvable by the time it is inspected.

## Why this plugin cannot fix it directly

`port_discovery.py` lives in the vendored `mcpforunityserver` Python package, not in this
repository - `agent-unity-wrapper` ships only skill content and a launch/adoption script
that wraps the external Unity MCP server (see `AGENTS.md`). This document is the
deliverable: a ready-to-file issue body, not a patch. Our own defensive cleanup
(`Remove-StaleAdoptionLinks` in the generated `.seretos/unity-mcp-launch.ps1`, ticket #47)
already deletes dangling adoption symlinks before every launch/adoption pass, which is our
side of the mitigation - this upstream fix would close the remaining gap for any dangling
link that survives long enough for a discovery scan to observe it in between.
