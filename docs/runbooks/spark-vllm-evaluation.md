# DGX Spark: vLLM evaluation plan

Decide whether vLLM replaces or supplements Ollama as the inference backend
behind LiteLLM. **Run this alongside the working Ollama, never in place of it.**

Status: **ROOT-CAUSED 2026-09-23.** Test 0 passed on both engines. Tests 1 and 2 ran
head-to-head and vLLM produced garbage; a systematic RCA localised that to one Marlin
kernel configuration and produced a two-line fix. Tests 1 and 2 then re-ran on the
fixed build against an idle box: **no material throughput win at Hindsight's context
length. Stay on Ollama.**

## What was actually wrong: Marlin's 256-thread fp4 MoE tile config on sm_121

`gpt-oss` on upstream vLLM (`cu130-nightly` 0.19.2rc1 **and** the v0.20.0 release) emits
**garbage on GB10 whenever more than one sequence is decoding**, and for short prompts
even at one sequence. HTTP 200 meant nothing: content-validated, **100% of c=8 responses
were garbage**; the `HarmonyError: channel marker present but no channel value found in
header` 500s were just the ~25% of garbage that happened to break the harmony parser.
Raw output (`/v1/completions`, `skip_special_tokens=False`) showed multilingual token
salad and `!!!!!` runs from the first generated token, **nondeterministic under greedy
decoding** — the signature of a kernel reading memory it should not.

The fault is in the **MXFP4 expert path**: `ops.moe_wna16_marlin_gemm` auto-selects a
**256-thread tile configuration** for gpt-oss's fp4 MoE GEMMs, and that configuration
miscomputes on sm_121. Forcing the **128-thread config** at the two call sites is a
complete fix:

```python
# vllm/model_executor/layers/fused_moe/fused_marlin_moe.py — both moe_wna16_marlin_gemm calls
use_fp32_reduce=True, thread_k=64, thread_n=128,
```

Result on the otherwise-untouched broken nightly: 24/24 header-clean across the rig
(81 and 16822 tokens, c=1 and c=8), content-validated chat **8 good / 0 garbage / 0
errors** — then **verified three more times**: 66/66 rig, 8/8 content, 0/16 HTTP, 0/16
streaming, the same bar NVIDIA's container was held to. The same two call sites
patched with `use_atomic_add=True` or `use_fp32_reduce=False` instead stay fully broken,
so the reduction path is not the mechanism; only the tile config is.

This matches the community finding for SM121 ("Marlin 256-thread race … forces 128
threads", ai-muninn / namake-taro fork), which is **not merged upstream**: vLLM
[#38126](https://github.com/vllm-project/vllm/pull/38126) fixes arch guards for 12.1 but
does not touch Marlin thread configs, and
[#52525](https://github.com/vllm-project/vllm/issues/52525) is ULP-scale reduction
nondeterminism, not this.

### Why NVIDIA's container is clean

`nvcr.io/nvidia/vllm:26.05-py3` (vLLM 0.20.1+nv, CUDA 13.2, NVIDIA torch 2.12, a
newer Triton snapshot) serves the same MXFP4 weights **clean: 66/66 rig, 8/8 content,
0/16 HTTP failures, streaming 0/16** — with the *same* `TRITON_ATTN` backend, the same
`Using 'MARLIN' Mxfp4 MoE backend` log line, and a `fused_marlin_moe.py` that is
**byte-identical** to stock v0.20.0. So NVIDIA did not fix it in Python; the difference
is in the compiled `_moe_C` (nvcc 13.2 vs 13.0.x and/or a source patch).
_(Which of those: pending — a run of NVIDIA's build forced onto the 256-thread config
will say whether their kernel is correct at 256 threads or merely avoids it.)_

### How the wrong turns were closed — every one by a single-variable test

| hypothesis | test | result |
| --- | --- | --- |
| harmony vocab `o200k_harmony.tiktoken` 404s | `strings` on the shipped extension | file never requested; real fetch is `o200k_base`; `TIKTOKEN_ENCODINGS_BASE` fixes startup |
| stale Triton cache (#41871) | inspect image + runtime cache | none present in a fresh container |
| request format / our payload | c=1 works; raw completions bypassing harmony | output corrupt before any parser |
| prompt length / sampling / server poisoning | 2×2 at c=1, length sweep, re-run of earlier-clean case | server not poisoned; temp irrelevant; short prompts fail even at c=1 |
| native `sm_121` SASS from nvcc 13.0 | `cuobjdump` on `_C`/`_moe_C` of 3 images | v0.20.0 ships **no** sm_121 SASS and is still broken; no build ships `sm_12xa` |
| vLLM code fix 0.19.2→0.20.0 | upstream v0.20.0 aarch64-cu130 image | still broken (0/8 content) |
| ptxas version (12.8 → 13.0 → NVIDIA's 13.2) | `TRITON_PTXAS_PATH` + `..._BLACKWELL_PATH` | still broken; NVIDIA's ptxas 12.8-swap refuses `sm_121a` (needs PTX ≥ 8.8) |
| Triton PTX ISA cap 86→90 (NVIDIA's diff) | one-line patch, proof via emitted `.ptx` (`.version 9.2`, `.target sm_121a`) | still broken |
| Triton codegen / LLVM | stock Triton 3.8.0 (LLVM 23) installed into the nightly | still broken |
| cuBLAS, RMSNorm, SDPA | batch-1 vs batch-8 identical-row kernel tests, both images | numerically identical between builds |
| int4 Marlin MoE | same kernel test, all tile/reduce variants | correct and **deterministic** — the fault is fp4-specific |
| Marlin reduction path | `use_atomic_add=True` / `use_fp32_reduce=False` on the real model | both still broken |
| **Marlin tile config** | **`thread_k=64, thread_n=128` on the real model** | **clean** |

Two of my own conclusions were wrong along the way and are corrected above: the
`o200k_harmony` 404 (a filename I assumed, never observed) and "ptxas exonerated" from a
test that had set the wrong knob. A "bf16 checkpoint" test was discarded as invalid — the
`unsloth/gpt-oss-20b-BF16` conversion is garbage on NVIDIA's clean build too.

### What to run

- **Vendor path (no patch):** `nvcr.io/nvidia/vllm:26.05-py3` with
  `TIKTOKEN_ENCODINGS_BASE` (harmony vocab) — clean out of the box.
- **Upstream path:** any `vllm/vllm-openai` cu130 image **plus** the two-line
  `thread_k=64, thread_n=128` patch bind-mounted over `fused_marlin_moe.py`, plus
  `TIKTOKEN_ENCODINGS_BASE`. Re-test on every image bump: count **content-validated
  garbage at c=8**, not HTTP 500s and not tok/s — both looked fine while output was noise.
- **Not fixes:** `VLLM_MXFP4_USE_MARLIN=0` (ignored: no `triton_kernels`, Marlin is the
  only fp4 backend), `VLLM_MARLIN_USE_ATOMIC_ADD` (dense path only; MoE call sites
  hardcode it), `CUDA_FORCE_PTX_JIT=1` (breaks SASS-only libs), a bf16 checkpoint.

### Tests 1 and 2 on the FIXED build, idle box, content-validated

Two runs, because the first one was wrong in a way worth recording.

**Identical prompts** (the naive benchmark): vLLM appeared to win 3.4× at c=8
(238 vs 69 tok/s, p50 2.7s vs 8.9s). The tell: vLLM's c=4 p50 (2.2s) was *lower than
c=1* (5.5s) — impossible unless the 23k-token prefill is being served from prefix cache
once and shared. It was. Hindsight's prompts differ per document; this number is void.

**Distinct ~23k-token prompts per request, greedy, 400 max tokens, every answer
content-checked:**

| c | Ollama p50 / aggregate | vLLM-fixed p50 / aggregate |
| --- | --- | --- |
| 1 | 6.7s / 20.4 tok/s | 6.5s / 17.0 tok/s |
| 4 | 22.1s / 15.0 tok/s | 18.4s / 17.9 tok/s |
| 8 | 39.1s / 17.5 tok/s | 34.9s / 19.2 tok/s |
| 16 | 79.9s / 17.0 tok/s | 68.4s / 18.5 tok/s |

Aggregate is flat in concurrency on **both** engines and latency scales linearly: at this
context length the workload is **prefill-bound** (~4.6k vs ~5.3k prompt tok/s), and
continuous batching is a *decode*-phase advantage. vLLM-fixed is ~10–15% faster on
latency. That is not worth a second engine, a bind-mounted kernel patch on every image
bump, or (the alternative) changing the production model to one vLLM serves unpatched.

**Verdict: stay on Ollama for gpt-oss.** Revisit only if the workload becomes
decode-heavy at short context (many concurrent short prompts), which is the regime where
vLLM's batching would actually pay. The queue-wait problem that started this was fixed
by `OLLAMA_NUM_PARALLEL` 4→8 (194s → 1.9s) and is unrelated to engine choice.

### Why 256 threads is wrong on GB10 — what is known and what is inferred

Forcing NVIDIA's build onto the 256-thread 128×128 config is **not possible**: the
kernel's own validity check rejects it during `profile_run` —

```
Invalid thread config: thread_m_blocks=4, thread_k=128, thread_n=128, num_threads=256
for MKN=[2048, 3072, 5888] … group_size=32 … max_shared_mem=101376
```

Two facts from that line. gpt-oss's real Marlin shapes are **K=3072, N=5888** (hidden
2880→3072, intermediate 2880→2944 after `mxfp4_round_up_…`). And GB10 exposes only
**101,376 bytes of shared memory per block**, against ~227 KB on datacenter Blackwell.

So on this chip the 256-thread configs sit right at the shared-memory validity edge, and
the auto-selector on the broken build picks one that passes the check yet computes wrong.
**Inference, not proven:** the fp4 template at group size 32 carries e8m0 scales per 32
elements — a larger shared-memory footprint than int4 — and if the C++ estimate
under-counts it, the kernel reads/writes shared memory out of bounds: nondeterministic
garbage, fp4-only, GB10-only. The 128-thread config has the headroom. NVIDIA's compiled
`_moe_C` (CUDA 13.2, possibly patched tables) is clean under auto-selection; whether it
picks 128 threads or has a correct 256-thread kernel could not be determined without the
source. It does not change the fix or the verdict.

## Test 0 — the decisive one. Run it first; stop if it fails

Everything else is irrelevant if vLLM cannot enforce Hindsight's schema.

**xgrammar's failure mode is silent under-constraint, not an error.**
[xgrammar #858](https://github.com/mlc-ai/xgrammar/issues/858) (open): when
`anyOf`/`oneOf`/`allOf` appears alongside `properties`/`required`, the
structural keywords are *silently dropped* and the grammar accepts "any JSON
value whatsoever". Related and also open:
[vLLM #56556](https://github.com/vllm-project/vllm/issues/56556) (fix PR
unmerged, needs rebase), [#57550](https://github.com/vllm-project/vllm/issues/57550),
[#26421](https://github.com/vllm-project/vllm/issues/26421).

`FactExtractionResponse` has nested `$defs`/`$ref`, an array of objects, an enum
and **four nullable `anyOf` fields**. It probably dodges #858 today — Pydantic
`Optional` emits `anyOf:[T, null]` with no sibling `properties` — but it is one
schema change away from silent garbage.

Therefore:

1. Pin the backend explicitly: **`--structured-outputs-config.backend guidance`**
   (llguidance). Do *not* leave it on `auto`, which selects xgrammar and, per
   #57550, mis-detects when `type` is omitted.
2. Extract the live schema from the running pod, not a hand-written copy:
   ```bash
   kubectl -n ai exec deploy/hindsight -c api -- python3 -c '
   import json,sys; sys.path.insert(0,"/app/api")
   from hindsight_api.engine.retain.fact_extraction import FactExtractionResponse
   print(json.dumps(FactExtractionResponse.model_json_schema()))'
   ```
3. Send it through vLLM and **validate the response against the schema**.

> ⚠️ "It returned JSON" is exactly the signal that cannot be trusted here. Under
> #858 the model returns *valid JSON that ignores the schema*. Assert every
> required `ExtractedFact` field is present, that `fact_type` is within its enum,
> and that no field violates its declared type. A pass that only checks
> `json.loads()` succeeded is a false pass.

Run it **20+ times**. Silent under-constraint is probabilistic — one clean
response proves nothing. Compare against Ollama on identical input; Ollama's
GBNF path is already verified on this schema including enum enforcement.

**If vLLM cannot match that, stop. Throughput gains are irrelevant.**

## Test 1 — latency, for the reflect path

Only if Test 0 passes.

Reflect's interactive path is capped client-side at 25s and cannot negotiate.
Measured on Ollama: a two-iteration tool loop runs **13.9s**.

Expect vLLM to lose here. Single-stream MXFP4 on GB10 is documented at ~32 tok/s
versus llama.cpp's 58, reaching 57–60 only after custom CUTLASS kernels, MXFP4
dense-layer quantization and FP8 KV cache
([NVIDIA forum](https://forums.developer.nvidia.com/t/vllm-on-gb10-gpt-oss-120b-mxfp4-slower-than-sglang-llama-cpp-what-s-missing/356651)).
A loss here does not kill the plan — it confirms reflect stays on Ollama.

## Test 2 — throughput, for the batch path

The case *for* vLLM. Published GB10 numbers: gpt-oss-120B MXFP4 goes **33.5 tok/s
at c=1 → 862.8 at c=256** (25.7×), collapsing at c=384
([Dendro Logic](https://dendro-logic.com/engineering/nvidia-dgx-spark-concurrency-benchmark/)).

Measure **aggregate throughput and per-request latency together**. At c=256 the
same source reports per-sequence decode of **3–4 tok/s**, meaning a 1024-token
response takes 4–5 minutes. That is acceptable for consolidation and retain; it
would be fatal for reflect.

Benchmark at the context length Hindsight actually uses (**32k**), not a short
prompt. A ~6k-token sweep previously showed 10-way concurrency holding latency
under 24s and that conclusion did not survive contact with real 32k payloads,
which ran 2–6 minutes.

**Benchmark only against an idle box.** Confirm `nvidia-smi` utilisation is near
zero and the Hindsight queue is empty first; a saturated GPU has already produced
one set of misleading numbers here.

### The `max-num-seqs` question is not a contradiction

NVIDIA's vLLM-on-Spark post recommends a **low** value (example: 4); third-party
benchmarks show gains to **256**. Both are correct for different objectives —
`4` optimises latency and small batches, `256` optimises aggregate throughput.
Which is right depends entirely on which instance you are configuring, and under
the split-backend design the answer is *both, in different processes*.

## Images

Do not build from source. Do not use a stock upstream image without checking.

| option | notes |
| --- | --- |
| [`eugr/spark-vllm-docker`](https://github.com/eugr/spark-vllm-docker) | best maintained; changelog through 2026-09-10, CUDA 13.0.2, torch 2.13.0 |
| `vllm/vllm-openai:cu130-nightly` | recommended by the [official vLLM DGX Spark post](https://vllm-project.github.io/2026/06/01/vllm-dgx-spark.html); pin a commit tag, not `nightly` |
| [Techno Tim `v0.20.1-gb10.0`](https://technotim.com/posts/vllm-gb10-docker/) | `sm_121a`, reproducible CI builds |

**sm_121 is no longer a blocker.**
[Issue #36821](https://github.com/vllm-project/vllm/issues/36821) is still open
but stale: [PR #52708](https://github.com/vllm-project/vllm/pull/52708) was
closed unmerged on 2026-09-14 because reviewers could not reproduce the kernel
failures on real GB10 and concluded the existing `12.0` targets are compatible.

## Operational facts that will look like failures

- **Cold start is ~425s** (JIT CUTLASS FP4 build), warm ~255s, against Ollama's
  5.5s. It looks hung. It is not. Do not restart it at the 2-minute mark.
- **One model per process.** Multi-model needs `llama-swap` or parallel
  instances — relevant if the split backend goes ahead.
- **Bare-metal installs need Python 3.12.** DGX OS ships 3.14, which has no ML
  wheels. Containers avoid this entirely.

## One thing vLLM is unambiguously better at

Its KV pool is **bounded** by `--gpu-memory-utilization` (the official blog uses
`0.65`). Ollama grows per slot, which is how a single evaluation request against
a dense 14B pinned **73 GiB** and took the box to 103 of 121 GiB — see
[`spark-console-display.md`](spark-console-display.md) sibling notes and the
`litellm` HelmRelease comment. A bounded pool cannot do that.

## Preconditions before starting

- Hindsight queue empty (`status IN ('pending','processing')` near zero)
- `nvidia-smi` utilisation near 0%
- `ollama ps` shows only `gpt-oss:20b`; evict anything else with
  `curl -d '{"model":"<name>","keep_alive":0}' .../api/generate`
- Enough free memory for both engines: Ollama holds ~13 GiB, so cap vLLM's
  `--gpu-memory-utilization` accordingly rather than letting it claim the default

## Exit criteria

Switch the batch stages to vLLM only if **all** hold:

1. Test 0 passes 20/20 with `guidance`, validated against the schema
2. Test 2 shows a material aggregate-throughput win at 32k context
3. Reflect stays on Ollama, or vLLM demonstrably clears 25s with margin

Otherwise stay on Ollama and revisit when the xgrammar `anyOf` fixes merge.
