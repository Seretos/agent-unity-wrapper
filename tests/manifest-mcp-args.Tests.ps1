# Ticket #59 - the wrapped Unity MCP server must be started with
# --project-scoped-tools so it registers execute_custom_tool and the
# custom_tools resource (mcpforunity://custom-tools).
#
# Pester 3.x. Static Describe always runs; the live Describe is opt-in:
#   $env:UNITY_WRAPPER_LIVE_MCP='1'; Invoke-Pester .\tests\manifest-mcp-args.Tests.ps1
# (needs uvx on PATH and network for the first download).

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

        It "$name manifest keeps the mcpforunityserver==9.7.1 pin" {
            $args_ = @((Get-MmaManifestServer $path).args)
            ($args_ -contains 'mcpforunityserver==9.7.1') | Should Be $true
        }
    }
}

# ---------------------------------------------------------------------------
# Live leg: start the server exactly as the manifest says (no editor) and ask
# it over newline-delimited JSON-RPC what it exposes.
# ---------------------------------------------------------------------------
$global:mma_skipLive = -not (($env:UNITY_WRAPPER_LIVE_MCP -eq '1') -and (Get-Command uvx -ErrorAction SilentlyContinue))

function Invoke-MmaLiveMcp {
    param([string]$ManifestPath, [int]$TimeoutSeconds = 180)

    $srv = Get-MmaManifestServer $ManifestPath
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('mma-live-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
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
        while ([DateTime]::UtcNow -lt $deadline -and -not ($responses.ContainsKey(2) -and $responses.ContainsKey(3))) {
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
            }
        }
        return $responses
    }
    finally {
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} }
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'unityMCP server started from the manifest exposes project-scoped tools (ticket #59 / R2, live, opt-in)' {

    foreach ($mf in $global:mma_manifests) {
        $name = $mf.Name
        $path = $mf.Path

        It -Skip:$global:mma_skipLive "$name manifest: tools/list has execute_custom_tool and resources/list has mcpforunity://custom-tools" {
            $r = Invoke-MmaLiveMcp -ManifestPath $path
            $r.ContainsKey(2) | Should Be $true
            $r.ContainsKey(3) | Should Be $true
            $toolNames = @($r[2].result.tools | ForEach-Object { $_.name })
            ($toolNames -contains 'execute_custom_tool') | Should Be $true
            $uris = @($r[3].result.resources | ForEach-Object { $_.uri })
            ($uris -contains 'mcpforunity://custom-tools') | Should Be $true
        }
    }
}
