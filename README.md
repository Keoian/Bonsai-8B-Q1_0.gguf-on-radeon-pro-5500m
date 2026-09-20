# Bonsai 8B (1-bit) on a Radeon Pro 5500M

A ready-to-run kit for PrismML's [1-bit Bonsai 8B](https://huggingface.co/prism-ml/Bonsai-8B-gguf)
on Windows with a Vulkan GPU: prebuilt llama.cpp binaries, two launchers, and a single-file chat UI.

**About 32 tokens/s** on an 8 GB AMD Radeon Pro 5500M (a 2019 MacBook Pro GPU), from a model file of
1.16 GB. The same settings fit a 6 GB card.

## Quick start

1. Download `Bonsai-8B-Q1_0.gguf` (1.16 GB) from
   [prism-ml/Bonsai-8B-gguf](https://huggingface.co/prism-ml/Bonsai-8B-gguf) into `models\`.
   SHA-256: `284a335aa3fb2ced3b1b01fcb40b08aa783e3b70832767f0dd2e3fdfa134bd54`
2. Pick a launcher, then open http://localhost:8080.

```
.\start-server-65k.ps1      # full 65k context, ~6.1 GB VRAM, needs an 8 GB card
.\start-server-32k.ps1      # 32k context, ~3.6 GB VRAM, fits a 6 GB card
```

Both take the same extra switches:

```
.\start-server-32k.ps1 -Lan                      # bind 0.0.0.0 for other machines on the LAN
.\start-server-65k.ps1 -NoFlashAttn              # reading a long document: ~8x faster (see below)
.\start-server-32k.ps1 -Cpu                      # CPU-only fallback, about 9 tok/s
.\start-server-65k.ps1 --reasoning-budget 2048   # unknown flags pass straight to llama-server
```

`start-server.ps1` is the underlying script if you want to set `-Ctx`, `-CacheK`, `-CacheV`, `-Ngl`,
`-Parallel`, `-Port` or `-ModelDir` yourself. `-Lan` exposes an unauthenticated API, so only use it on
a trusted network or add `--api-key <key>`.

If a browser shows a stale page at `localhost:8080`, open `http://127.0.0.1:8080` or clear the site
data. llama-server's built-in UI can leave a service worker behind.

## VRAM

Measured on the Radeon Pro 5500M, and cross-checked against what Windows reports for the process
(within about 30 MiB of each total, so there is little driver overhead on top).

| Cache | Context | Weights | KV cache | Compute | Total |
|---|---|---|---|---|---|
| q8_0 | 16k | 1,016 MiB | 1,224 MiB | 104 MiB | **2,344 MiB** |
| **q8_0 (default 32k)** | **32k** | 1,016 MiB | 2,448 MiB | 120 MiB | **3,584 MiB** |
| q4_0 | 65k | 1,016 MiB | 2,592 MiB | 152 MiB | **3,760 MiB** |
| f16 | 32k | 1,016 MiB | 4,608 MiB | 120 MiB | **5,744 MiB** |
| **q8_0 (default 65k)** | **65k** | 1,016 MiB | 4,896 MiB | 152 MiB | **6,064 MiB** |
| f16 | 65k | — | — | — | out of memory |

The cache dominates, not the weights. A 1-bit 8B is about 1 GiB, but quantization does not touch the
cache: 36 layers with 8 key-value heads is 144 KiB per token at f16 and 72 KiB at q8_0.

**On a 6 GB card** (GTX 1060 6 GB and similar) use `start-server-32k.ps1`: 3.6 GB leaves room for the
desktop. The 65k default needs 6.1 GB and will not fit. If you want the full context on 6 GB, use a
4-bit cache instead: `.\start-server.ps1 -Ctx 65536 -CacheK q4_0 -CacheV q4_0` is 3.8 GB.

## Speed

`llama-bench`, 512-token prompt and 64-token generation, all layers on the GPU:

| Config | Prompt | Decode |
|---|---|---|
| Vulkan, flash attention on (default) | 175 t/s | **31.8 tok/s** |
| Vulkan, forced integer-dot mat-vec | 174 t/s | 31.7 tok/s |
| Vulkan, flash attention off | 187 t/s | 27.0 tok/s |
| CPU, 8 threads (i9-9980HK) | 128 t/s | 9.1 tok/s |

`GGML_VK_FORCE_MMVQ=1` changes nothing here, so the launcher leaves it alone.

Decode by context and cache format, measured through the server on the same short request:

| Keys / values | Context | Decode |
|---|---|---|
| f16 / f16 | 32k | 31.5 tok/s |
| q8_0 / q8_0 | 32k | 31.4 tok/s |
| q8_0 / q8_0 | 65k | 29.7 tok/s |
| q8_0 / q4_0 | 65k | 29.5 tok/s |
| q4_0 / q4_0 | 65k | 29.8 tok/s |

The cache format costs no speed on this card. Context length does, about 6% from 32k to 65k, because
a longer cache means more memory traffic per token.

## Flash attention: the setting that matters most

Vulkan flash attention has no accelerated path on this card (the Vulkan device reports no matrix
cores) and llama.cpp falls back to a slow route. This is an upstream issue, not Bonsai-specific:
[#17715](https://github.com/ggml-org/llama.cpp/issues/17715),
[#12629](https://github.com/ggml-org/llama.cpp/discussions/12629),
[#27137](https://github.com/ggml-org/llama.cpp/issues/27137).

`llama-bench` at fixed context depth:

| Depth | Prompt, on | Prompt, off | Decode, on | Decode, off |
|---|---|---|---|---|
| 4k | 21 t/s | **128 t/s** | **26 tok/s** | 19 tok/s |
| 8k | 11 t/s | **118 t/s** | **15 tok/s** | 9.6 tok/s |

Two modes for two jobs:

- **Chat (default, on).** Replies are decode-bound, and the prompt cache means each turn only
  processes your new message, so faster decode wins.
- **Long documents (`-NoFlashAttn`).** A 25,200-token prompt was read in **5 minutes** (82.7 t/s) and
  the model correctly recalled a code word planted near the start. With flash attention on, the same
  prompt was still processing after 40 minutes and never finished: throughput decays with depth,
  25 t/s at 8k down to 11 t/s at 18k. The cost is slow replies afterwards, 5.4 tok/s at that depth.

`-NoFlashAttn` forces an f16 cache, because quantized caches require flash attention, and caps
context at 32k to fit. It also lowers the micro-batch: without flash attention the attention scores
are materialized in full (4 bytes x 32 heads x micro-batch x context), so the default micro-batch of
512 tries to allocate 2 GiB and the server dies. The launcher sizes it for a 768 MiB budget, which is
192 at 32k context and prefills a 2.5k-token prompt at 168 t/s, against 78 t/s at a micro-batch of 32.

## Quality

Not measured on this model yet. The KV cache comparison (f16 against q8_0, WikiText-2 perplexity) has
not been run here. For reference, on the 27B ternary Bonsai the same test showed no change at a 2k
window and +0.36% perplexity at 16k using a more aggressive setting (8-bit keys, 4-bit values), so
the q8_0 default here is expected to be close to lossless. Treat that as inference, not measurement.

## Chat UI

`webui/index.html` is one file with no dependencies, served by the launcher in place of
llama-server's built-in UI.

- Streams replies, shows decode and prompt speed for every reply from the server's own timings.
- Sampling controls, presets from the model card (temperature 0.5, top-p 0.9, top-k 20), system
  prompt, light/dark theme.
- Settings and the current chat live in the browser's local storage only.

Bonsai 8B is text-only and not a reasoning model, so there is no image attach and the reasoning
control defaults to off.

## The binaries

`bin/` holds a Windows x64 build of the [PrismML llama.cpp fork](https://github.com/PrismML-Eng/llama.cpp)
(MSVC 2022, Vulkan plus all CPU variants, selected at runtime). `Q1_0` support is merged upstream in
llama.cpp, so a stock build runs this model at the same speed; the fork is only required for the
newer Bonsai 2 ternary formats.

To build your own, see the sibling kit at
[bonsai2-on-radeon-pro-5500m](https://github.com/Keoian/bonsai2-on-radeon-pro-5500m), which documents
the CMake configuration and carries the Vulkan patches for the 27B model.

If the binaries complain about missing VCRUNTIME or MSVCP DLLs, install the Microsoft Visual C++
redistributable. GPU machines need a Vulkan-capable driver; no Vulkan SDK is needed at runtime.

Tested on: Windows 11, AMD Boot Camp driver 32.0.12019.1028, Radeon Pro 5500M 8 GB, i9-9980HK,
32 GB RAM.

## License

llama.cpp and the PrismML fork are MIT licensed. The Bonsai 8B weights carry their own license, see
the model card.
