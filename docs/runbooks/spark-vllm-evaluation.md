# DGX Spark: vLLM evaluation plan

Decide whether vLLM replaces or supplements Ollama as the inference backend
behind LiteLLM. **Run this alongside the working Ollama, never in place of it.**

Status: **BLOCKED upstream, 2026-09-22.** Test 0 passed on both engines (20/20).
Tests 1 and 2 cannot be run on the production model, and the reason is not
fixable from here.

## ⚠️ vLLM cannot serve gpt-oss: the harmony vocab 404s

`vllm/vllm-openai:cu130-nightly --model openai/gpt-oss-20b` dies ~8 minutes into
startup with:

```
openai_harmony.HarmonyError: error downloading or loading vocab file
```

It reads like a network or proxy problem and is neither. Measured from both the
Spark and inside the container:

| file | result |
| --- | --- |
| `o200k_base.tiktoken` | 200, 3,613,922 bytes |
| `cl100k_base.tiktoken` | 200, 1,681,126 bytes |
| **`o200k_harmony.tiktoken`** | **404** |

Container egress is fine (`github.com` → 200, and the CDN itself serves the
other two files to the same container). The one file harmony actually needs is
simply not published. It is not mirrored anywhere reachable either — checked
`openai/gpt-oss-20b` on HF (404), the `openai/harmony` HF dataset (401) and
`raw.githubusercontent.com/openai/harmony` (404) — and the Python layer exposes
no env var to point the loader at a local copy.

**Do not re-debug this as a proxy, DNS or CUDA problem.** Re-test by curling
`https://openaipublic.blob.core.windows.net/encodings/o200k_harmony.tiktoken`
and looking for a 200. Until that returns one, vLLM cannot serve this model.

### vLLM itself is FINE on this hardware — the blocker is gpt-oss alone

Proven, not inferred. The same image, same box, same day:

```
--model Qwen/Qwen2.5-1.5B-Instruct  ->  started in ~195s, served a completion
```

and a clean boot logs **zero** mentions of harmony. `openai_harmony` is loaded
only for gpt-oss, because the harmony response format is that model family's
own; every other architecture skips the code path entirely.

So this is NOT evidence against vLLM on GB10/aarch64/CUDA 13 — it runs. Anyone
reading this later should not conclude "vLLM does not work on the Spark". It
does. What does not work is **vLLM + gpt-oss**, for as long as that one file is
unpublished.

The practical consequence is unchanged, because gpt-oss is what production
runs: serving anything else on vLLM means changing the production model, which
is a quality decision rather than a benchmark, and would invalidate the
per-stage tuning built around gpt-oss's behaviour.

### Why that makes Tests 1 and 2 moot rather than merely delayed

They exist to decide whether retain and consolidation move to vLLM. Running them
against a substitute model would not answer that: vLLM would be serving
something we do not run, at a different quantization (Ollama serves Q4; a plain
HF checkpoint is fp16, roughly 4x the bytes per token on a bandwidth-bound
device), so any throughput comparison would measure the quantization, not the
engine.

The honest options are therefore (a) wait for the vocab to be published, or
(b) decide independently to move production off gpt-oss to a model vLLM can
serve — which is a model-quality decision, not a benchmark, and would invalidate
the per-stage tuning that is currently built around gpt-oss's behaviour.

### The pressure behind this has also dropped

The problem that motivated a second engine was queue wait: with
`OLLAMA_NUM_PARALLEL=4` (sized exactly to hindsight's per-stage caps) the newly
migrated apps had zero slots and a trivial request took 194s. Raising it to 8
took that to 1.9s. See `spark-setup` `group_vars/all.yml` for the measured
trade. vLLM is no longer needed to fix an outage; it is an optimisation, which
is a much weaker reason to accept a model change.

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
