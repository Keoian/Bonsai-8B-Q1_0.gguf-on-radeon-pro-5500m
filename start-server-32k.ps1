<#
.SYNOPSIS
  Bonsai 8B with a 32k context and a q8_0 KV cache. Uses about 3.6 GB of VRAM, so it fits on a
  6 GB card (GTX 1060 6 GB and similar) with room for the desktop.

.DESCRIPTION
  Thin wrapper over start-server.ps1. Every other switch still works and passes through, e.g.
    .\start-server-32k.ps1 -Lan
    .\start-server-32k.ps1 -NoFlashAttn
    .\start-server-32k.ps1 --reasoning-budget 2048

  VRAM at these settings: 1,016 MiB weights + 2,448 MiB KV cache + 120 MiB compute = 3,584 MiB.
#>
& (Join-Path $PSScriptRoot "start-server.ps1") -Ctx 32768 -CacheK q8_0 -CacheV q8_0 @args
exit $LASTEXITCODE
