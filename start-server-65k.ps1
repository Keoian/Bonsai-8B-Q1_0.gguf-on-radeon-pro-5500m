<#
.SYNOPSIS
  Bonsai 8B with the full 65k training context and a q8_0 KV cache. Uses about 6.1 GB of VRAM, so
  it needs an 8 GB card. On a 6 GB card use start-server-32k.ps1 instead.

.DESCRIPTION
  Thin wrapper over start-server.ps1. Every other switch still works and passes through, e.g.
    .\start-server-65k.ps1 -Lan
    .\start-server-65k.ps1 --reasoning-budget 2048

  VRAM at these settings: 1,016 MiB weights + 4,896 MiB KV cache + 152 MiB compute = 6,064 MiB.
  Decode is about 6% slower than at 32k (29.7 vs 31.5 tok/s), which is the cost of the longer
  cache, not of quantizing it.
#>
& (Join-Path $PSScriptRoot "start-server.ps1") -Ctx 65536 -CacheK q8_0 -CacheV q8_0 @args
exit $LASTEXITCODE
