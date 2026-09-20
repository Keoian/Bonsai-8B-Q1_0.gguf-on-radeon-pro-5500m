<#
.SYNOPSIS
  Start llama-server for Bonsai 8B (1-bit, Q1_0) with tuned Vulkan settings and serve the chat UI.

.EXAMPLE
  .\start-server.ps1                 # Vulkan, Q1_0, 65k context, q8_0 KV cache (needs an 8 GB card)
  .\start-server-65k.ps1             # same thing, named for clarity
  .\start-server-32k.ps1             # 32k context, ~3.6 GB VRAM, fits a 6 GB card
  .\start-server.ps1 -NoFlashAttn    # 10x faster prompt processing for long documents, slower replies
  .\start-server.ps1 -Lan            # also reachable from other machines on the LAN
  .\start-server.ps1 -Cpu            # CPU only, for machines without a usable GPU
  .\start-server.ps1 -Parallel 4     # more concurrent chats (each slot costs VRAM)
  .\start-server.ps1 --reasoning-budget 2048   # unknown flags pass straight to llama-server

  .\start-server.ps1 -ModelDir D:\models   # where the .gguf files live (see below)

  Then open http://localhost:8080 in a browser.

  Model files are looked up in: -ModelDir, then $env:BONSAI_MODEL_DIR, then .\models next to this
  script. The server binaries are expected in .\bin next to this script.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch] $Lan,
    [switch] $Cpu,
    # Vulkan flash attention has no accelerated path on this card (no matrix cores), and upstream
    # llama.cpp takes a slow route for it. Measured at 4k/8k context depth: with -fa on, prompt
    # processing is ~21/11 t/s and decode ~26/15 tok/s; with -NoFlashAttn, prompt processing is
    # ~128/118 t/s and decode ~19/9.6 tok/s. Chat replies are decode-bound, so -fa on is the default.
    # Use -NoFlashAttn when feeding in a long document, where prefill dominates (10x faster).
    [switch] $NoFlashAttn,
    [int]    $Ctx = 65536,
    # KV cache precision. Bonsai 8B has a big cache for its size (36 layers, 8 KV heads): 144 KiB
    # per token at f16, 72 KiB at q8_0. Measured on this card: the cache format costs no speed
    # (31.5 tok/s at 32k with f16, 31.4 with q8_0), the context length does (29.7 tok/s at 65k).
    # So the default keeps the full 65k context and pays for it with a q8_0 cache. f16 only fits
    # to 32k; asking for more with f16 auto-switches to q8_0 below.
    [ValidateSet("f16", "q8_0", "q4_0")] [string] $CacheK = "q8_0",
    [ValidateSet("f16", "q8_0", "q4_0")] [string] $CacheV = "q8_0",
    [int]    $Port = 8080,
    [int]    $Ngl = 99,
    [int]    $Parallel = 1,
    [string] $ModelDir,
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $Extra
)

$ErrorActionPreference = "Stop"
$Root  = $PSScriptRoot
$Bin   = Join-Path $Root "bin\llama-server.exe"
$WebUI = Join-Path $Root "webui"

if (-not (Test-Path $Bin)) { throw "llama-server.exe not found at $Bin (see RUN.md)" }

$Gguf = "Bonsai-8B-Q1_0.gguf"
$Candidates = @($ModelDir, $env:BONSAI_MODEL_DIR, (Join-Path $Root "models")) | Where-Object { $_ }
$Models = $Candidates | Where-Object { Test-Path (Join-Path $_ $Gguf) } | Select-Object -First 1
if (-not $Models) { throw "$Gguf not found. Looked in: $($Candidates -join '; '). Pass -ModelDir." }

if ($Cpu) { $Ngl = 0 }

# An f16 cache past 32k does not fit in 8 GB and llama-server dies with ErrorOutOfDeviceMemory.
# Quantize it instead of failing, unless the caller asked for a specific format.
if (-not $Cpu -and $Ctx -gt 32768 -and $CacheK -eq "f16" -and -not $PSBoundParameters.ContainsKey("CacheK")) {
    $CacheK = "q8_0"
    if (-not $PSBoundParameters.ContainsKey("CacheV")) { $CacheV = "q8_0" }
    Write-Host "  [note] context > 32k: KV cache set to q8_0 so it fits in 8 GB (override with -CacheK/-CacheV)" -ForegroundColor Yellow
}

# A quantized KV cache requires flash attention, so fall back to f16 (and its 32k ceiling).
if ($NoFlashAttn -and ($CacheK -ne "f16" -or $CacheV -ne "f16")) {
    $CacheK = "f16"; $CacheV = "f16"
    Write-Host "  [note] -NoFlashAttn needs an f16 KV cache; cache format reset" -ForegroundColor Yellow
    if ($Ctx -gt 32768) {
        $Ctx = 32768
        Write-Host "  [note] context capped at 32768: an f16 cache past that does not fit in 8 GB" -ForegroundColor Yellow
    }
}

# Without flash attention the attention scores are materialized in full: 4 bytes x 32 heads x
# micro-batch x context. At the default micro-batch of 512 and 32k context that is 2 GiB per buffer
# and the server dies allocating it, so shrink the micro-batch unless the caller set one.
$UBatch = 0
if ($NoFlashAttn -and -not $Cpu -and ($Extra -notcontains "-ub") -and ($Extra -notcontains "--ubatch-size")) {
    # 768 MiB of scores: measured at 32k context, that lands on 192, which prefills a 2.5k-token
    # prompt at ~168 t/s. A micro-batch of 32 drops that to 78 t/s, and 512 runs out of memory.
    $UBatch = [Math]::Max(64, [int](805306368 / (4 * 32 * $Ctx)))
    $UBatch = [Math]::Min(512, $UBatch)
}

$GgufPath = Join-Path $Models $Gguf
if (-not (Test-Path $GgufPath)) { throw "model not found: $GgufPath" }

$BindHost = if ($Lan) { "0.0.0.0" } else { "127.0.0.1" }

# Sampling per the Bonsai 8B model card. The web UI overrides these per request.
$Args_ = @(
    "-m", $GgufPath,
    "--host", $BindHost, "--port", "$Port",
    "-ngl", "$Ngl", "-fa", $(if ($NoFlashAttn) { "off" } else { "on" }),
    "-c", "$Ctx",
    "-np", "$Parallel",
    "-ctk", $CacheK, "-ctv", $CacheV,
    "--temp", "0.5", "--top-p", "0.9", "--top-k", "20",
    "--jinja",
    "--path", $WebUI,
    "--slots"
)
if ($Cpu) { $Args_ += @("-t", [Math]::Max(1, [Environment]::ProcessorCount / 2)) }
if ($UBatch -gt 0) { $Args_ += @("-ub", "$UBatch", "-b", "$([Math]::Max($UBatch, 512))") }
# Bonsai 8B is text-only: no mmproj / vision projector exists for it.
if ($Extra) { $Args_ += ($Extra | Where-Object { $_ -ne "--" }) }

Write-Host ""
Write-Host "=== Bonsai 8B (1-bit) / llama-server ===" -ForegroundColor Green
Write-Host "  Model:   $Gguf"
Write-Host ("  Backend: " + $(if ($Ngl -gt 0) { "Vulkan, -ngl $Ngl" } else { "CPU" }))
Write-Host ("  Context: $Ctx (KV cache K=$CacheK V=$CacheV, flash attention " + $(if ($NoFlashAttn) { "off)" } else { "on)" }))
if ($UBatch -gt 0) { Write-Host "  Micro-batch: $UBatch (keeps the no-flash-attention score buffer small)" }
Write-Host ("  UI:      http://localhost:$Port" + $(if ($Lan) { "  (LAN: http://$((Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.*' } | Select-Object -First 1).IPAddress):$Port)" } else { "" }))
Write-Host "  API:     http://localhost:$Port/v1/chat/completions"
Write-Host "  Ctrl+C stops the server."
Write-Host ""

# llama-server logs to stderr; "Stop" would abort on the first log line when output is redirected.
$ErrorActionPreference = "Continue"
& $Bin @Args_
exit $LASTEXITCODE
