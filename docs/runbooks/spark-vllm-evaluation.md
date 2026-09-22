# DGX Spark: vLLM evaluation plan

Decide whether vLLM replaces or supplements Ollama as the inference backend
behind LiteLLM. **Run this alongside the working Ollama, never in place of it.**

Status: planned, not yet executed.

## The verdict this plan is testing

Research (2026-09-22) landed on **trial alongside, do not switch**, and the
reason is specific: Hindsight puts a hard 25s latency SLA (reflect) and batch
work (retain, consolidation) on one engine. vLLM's entire advantage is aggregate
throughput **purchased with per-request latency** — the exact trade that broke
this cluster at Ollama concurrency 10.

So the interesting outcome is not "which engine wins". It is whether a **split
backend** beats either alone: Ollama serving reflect (latency), vLLM serving
retain and consolidation (throughput). LiteLLM already routes per `model_name`
and Hindsight already selects a model per stage, so this is configuration, not
architecture.

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
