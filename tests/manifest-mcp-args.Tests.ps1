# Ticket #59 - the wrapped Unity MCP server must be started with
# --project-scoped-tools so it registers execute_custom_tool and the
# custom_tools resource (mcpforunity://custom-tools).
#
# Pester 3.x. Static Describe always runs; the live Describe is opt-in:
#   $env:UNITY_WRAPPER_LIVE_MCP='1'; Invoke-Pester .\tests\manifest-mcp-args.Tests.ps1
# (needs uvx on PATH and network for the first download).
#
# Ticket #64 - live-editor check (opt-in): with a Unity editor already running
# for a checkout via environment_start, and that project defining a
# [McpForUnityTool] tool, run:
#   $env:UNITY_WRAPPER_LIVE_EDITOR_CHECKOUT='<abs path of the checkout>'
#   $env:UNITY_WRAPPER_LIVE_CUSTOM_TOOL='<tool name, e.g. world_describe>'
#   Invoke-Pester .	ests\manifest-mcp-args.Tests.ps1
# It asserts tool reachability only (execute_custom_tool returns the tool's
# real result, and the tool's own name is in tools/list). It deliberately does
# NOT assert tool_count > 0 on mcpforunity://custom-tools: under stdio that
# resource may stay empty, because each project tool is registered as its own
# named MCP tool instead.

$global:mma_repoRoot = Split-Path -Parent $PSScriptRoot
$global:mma_manifests = @(
    @{ Name = 'Claude'; Path = (Join-Path $global:mma_repoRoot '.claude-plugin\plugin.json') },
    @{ Name = 'Codex';  Path = (Join-Path $global:mma_repoRoot '.codex-plugin\plugin.json') }
)

function Get-MmaManifestServer {
    param([string]$Path)
    $m = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    return $m.mcpServers.unityMCP
}

function Get-MmaScriptPinVersion {
    $script = Join-Path $global:mma_repoRoot 'scripts\prepare-unity-worktree.ps1'
    $m = [regex]::Match((Get-Content -LiteralPath $script -Raw), "\[string\]\`$UnityMcpVersion\s*=\s*'([^']+)'")
    if (-not $m.Success) { throw 'UnityMcpVersion default not found in prepare-unity-worktree.ps1' }
    return $m.Groups[1].Value
}

Describe 'plugin manifests - unityMCP args (ticket #59 / R1)' {

    foreach ($mf in $global:mma_manifests) {
        $name = $mf.Name
        $path = $mf.Path

        It "$name manifest passes --project-scoped-tools exactly once" {
            $args_ = @((Get-MmaManifestServer $path).args)
            @($args_ | Where-Object { $_ -eq '--project-scoped-tools' }).Count | Should Be 1
        }

        # Placed before the entry-point arg, uvx would consume the flag as its
        # own option and the server would never see it.
        It "$name manifest passes --project-scoped-tools after the mcp-for-unity entry point" {
            $args_ = @((Get-MmaManifestServer $path).args)
            $entry = [array]::IndexOf($args_, 'mcp-for-unity')
            $flag = [array]::IndexOf($args_, '--project-scoped-tools')
            ($entry -ge 0) | Should Be $true
            ($flag -gt $entry) | Should Be $true
        }

        It "$name manifest keeps --transport stdio adjacent" {
            $args_ = @((Get-MmaManifestServer $path).args)
            $i = [array]::IndexOf($args_, '--transport')
            ($i -ge 0) | Should Be $true
            $args_[$i + 1] | Should Be 'stdio'
        }

        # Single source of truth: the -UnityMcpVersion default of the prepare
        # script. Manifests (server pin) and the bridge default must agree.
        It "$name manifest pin equals the prepare script's UnityMcpVersion default" {
            $args_ = @((Get-MmaManifestServer $path).args)
            $from = [array]::IndexOf($args_, '--from')
            ($from -ge 0) | Should Be $true
            $args_[$from + 1] | Should Be ('mcpforunityserver==' + (Get-MmaScriptPinVersion))
        }
    }
}

Describe 'unity-mcp pin source of truth (ticket #64 / R1)' {
    It 'prepare-unity-worktree.ps1 -UnityMcpVersion default is a 10.x version' {
        (Get-MmaScriptPinVersion) | Should Match '^10\.\d+\.\d+$'
    }
    It 'prepare-unity-worktree.ps1 -UnityMcpVersion default is 10.3.0' {
        (Get-MmaScriptPinVersion) | Should Be '10.3.0'
    }
}

# ---------------------------------------------------------------------------
# Live leg: start the server exactly as the manifest says (no editor) and ask
# it over newline-delimited JSON-RPC what it exposes.
# ---------------------------------------------------------------------------
$global:mma_skipLive = -not (($env:UNITY_WRAPPER_LIVE_MCP -eq '1') -and (Get-Command uvx -ErrorAction SilentlyContinue))

function Invoke-MmaLiveMcp {
    param([string]$ManifestPath, [int]$TimeoutSeconds = 180,
          [string]$ProjectDir, [object[]]$Requests = @(), [scriptblock]$Predicate)

    $srv = Get-MmaManifestServer $ManifestPath
    $ownTmp = [string]::IsNullOrEmpty($ProjectDir)
    if ($ownTmp) {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('mma-live-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
    } else { $tmp = $ProjectDir }
    $proc = $null
    try {
        $resolve = { param($s) ([string]$s).Replace('${CLAUDE_PROJECT_DIR}', $tmp) }
        $argList = @($srv.args | ForEach-Object { & $resolve $_ })

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Command ([string]$srv.command)).Source
        $quoted = $argList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }
        $psi.Arguments = ($quoted -join ' ')
        $psi.WorkingDirectory = $tmp
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        foreach ($p in $srv.env.PSObject.Properties) {
            $psi.EnvironmentVariables[$p.Name] = (& $resolve $p.Value)
        }
        $proc = [System.Diagnostics.Process]::Start($psi)
        $null = $proc.StandardError.ReadToEndAsync()

        $send = {
            param($obj)
            $proc.StandardInput.WriteLine(($obj | ConvertTo-Json -Compress -Depth 10))
            $proc.StandardInput.Flush()
        }
        & $send @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{
            protocolVersion = '2024-11-05'; capabilities = @{}
            clientInfo = @{ name = 'manifest-mcp-args-test'; version = '0' } } }

        $responses = @{}
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $sent = $false
        $pending = $null
        $lastExtra = [DateTime]::MinValue
        $done = {
            if (-not ($responses.ContainsKey(2) -and $responses.ContainsKey(3))) { return $false }
            if ($Predicate) { return [bool](& $Predicate $responses) }
            foreach ($rq in $Requests) { if (-not $responses.ContainsKey([int]$rq.id)) { return $false } }
            return $true
        }
        while ([DateTime]::UtcNow -lt $deadline -and -not (& $done)) {
            # Extra requests are re-sent every 5 s: the server's sync from the
            # editor may land after the first answer.
            if ($sent -and $Requests.Count -gt 0 -and ([DateTime]::UtcNow - $lastExtra).TotalSeconds -ge 5) {
                $lastExtra = [DateTime]::UtcNow
                foreach ($rq in $Requests) { & $send $rq }
            }
            if ($null -eq $pending) { $pending = $proc.StandardOutput.ReadLineAsync() }
            if (-not $pending.Wait(1000)) { continue }
            $line = $pending.Result
            $pending = $null
            if ($null -eq $line) { break }
            try { $msg = $line | ConvertFrom-Json } catch { continue }
            if ($null -ne $msg.id) { $responses[[int]$msg.id] = $msg }
            if (-not $sent -and $responses.ContainsKey(1)) {
                $sent = $true
                & $send @{ jsonrpc = '2.0'; method = 'notifications/initialized' }
                & $send @{ jsonrpc = '2.0'; id = 2; method = 'tools/list'; params = @{} }
                & $send @{ jsonrpc = '2.0'; id = 3; method = 'resources/list'; params = @{} }
                $lastExtra = [DateTime]::UtcNow
                foreach ($rq in $Requests) { & $send $rq }
            }
        }
        return $responses
    }
    finally {
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} }
        if ($ownTmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'unityMCP server started from the manifest exposes project-scoped tools (ticket #59 / R2, live, opt-in)' {

    foreach ($mf in $global:mma_manifests) {
        $name = $mf.Name
        $path = $mf.Path

        It -Skip:$global:mma_skipLive "$name manifest: tools/list has execute_custom_tool and resources/list has mcpforunity://custom-tools" {
            $r = Invoke-MmaLiveMcp -ManifestPath $path
            $r.ContainsKey(1) | Should Be $true
            $r.ContainsKey(2) | Should Be $true
            $r.ContainsKey(3) | Should Be $true
            # A real launch of the pinned server answers initialize with a serverInfo.
            [string]$r[1].result.serverInfo.name | Should Not BeNullOrEmpty
            $toolNames = @($r[2].result.tools | ForEach-Object { $_.name })
            ($toolNames -contains 'execute_custom_tool') | Should Be $true
            $uris = @($r[3].result.resources | ForEach-Object { $_.uri })
            ($uris -contains 'mcpforunity://custom-tools') | Should Be $true
        }
    }
}

# ---------------------------------------------------------------------------
# Ticket #64 live-editor leg: needs a running editor (environment_start) for
# the checkout in UNITY_WRAPPER_LIVE_EDITOR_CHECKOUT and a project tool name
# in UNITY_WRAPPER_LIVE_CUSTOM_TOOL. Asserts reachability only; tool_count on
# mcpforunity://custom-tools is NOT asserted (may stay empty under stdio).
# ---------------------------------------------------------------------------
$global:mma_skipEditor = [string]::IsNullOrEmpty($env:UNITY_WRAPPER_LIVE_EDITOR_CHECKOUT) -or [string]::IsNullOrEmpty($env:UNITY_WRAPPER_LIVE_CUSTOM_TOOL) -or -not (Get-Command uvx -ErrorAction SilentlyContinue)

Describe 'unityMCP project tool is reachable through a live editor (ticket #64, live-editor, opt-in)' {

    foreach ($mf in $global:mma_manifests) {
        $name = $mf.Name
        $path = $mf.Path

        It -Skip:$global:mma_skipEditor "$name manifest: execute_custom_tool runs the project's tool and tools/list names it" {
            $tool = $env:UNITY_WRAPPER_LIVE_CUSTOM_TOOL
            $reqs = @(
                @{ jsonrpc = '2.0'; id = 10; method = 'tools/call'; params = @{
                    name = 'execute_custom_tool'
                    arguments = @{ tool_name = $tool; parameters = @{} } } }
            )
            $notFound = { param($r) ($r | ConvertTo-Json -Depth 10 -Compress) -match 'not found' }
            $pred = {
                param($r)
                $r.ContainsKey(10) -and -not (& $notFound $r[10])
            }
            $r = Invoke-MmaLiveMcp -ManifestPath $path -ProjectDir $env:UNITY_WRAPPER_LIVE_EDITOR_CHECKOUT `
                -Requests $reqs -Predicate $pred -TimeoutSeconds 120
            $r.ContainsKey(10) | Should Be $true
            (& $notFound $r[10]) | Should Be $false
            $toolNames = @($r[2].result.tools | ForEach-Object { $_.name })
            ($toolNames -contains $tool) | Should Be $true
        }
    }
}
