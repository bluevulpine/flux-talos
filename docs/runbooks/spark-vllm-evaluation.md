# DGX Spark: vLLM evaluation plan

Decide whether vLLM replaces or supplements Ollama as the inference backend
behind LiteLLM. **Run this alongside the working Ollama, never in place of it.**

Status: **EXECUTED 2026-09-22. Verdict: stay on Ollama.** Test 0 passed on both
engines. Tests 1 and 2 ran head-to-head. vLLM is not viable for gpt-oss here,
and the reason is reliability, not speed.

## The verdict, and two wrong turns taken to reach it

### ⚠️ The startup blocker was real but MISDIAGNOSED — and it has a fix

`--model openai/gpt-oss-20b` dies ~8 min into startup with
`HarmonyError: error downloading or loading vocab file`.

The first diagnosis recorded here was that
`openaipublic.blob.core.windows.net/encodings/o200k_harmony.tiktoken` returns
404. It does — **but nothing ever requests it.** That filename was assumed, not
observed. `strings` on the shipped `openai_harmony` extension finds
`o200k_base.tiktoken` and **zero** occurrences of `o200k_harmony.tiktoken`:
harmony reuses the o200k_base vocab and layers its special tokens on at load.
Confirming the absence of a file nothing asks for proved nothing.

The real failure is the `o200k_base.tiktoken` fetch failing inside harmony's
Rust HTTP client even though `curl` to the same URL from the same container
succeeds — a long-standing, still-open packaging gap
([vllm#22525](https://github.com/vllm-project/vllm/issues/22525),
[harmony#46](https://github.com/openai/harmony/issues/46),
[harmony#101](https://github.com/openai/harmony/issues/101), and
[NVIDIA/dgx-spark-playbooks#17](https://github.com/NVIDIA/dgx-spark-playbooks/issues/17)
for this exact box).

**Fix, verified working here** — pre-download the vocab and bypass the fetch:

```bash
sudo mkdir -p /opt/tiktoken_encodings
sudo curl -sSL -o /opt/tiktoken_encodings/o200k_base.tiktoken \
  https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken
# then, on the container:
#   -v /opt/tiktoken_encodings:/tiktoken_encodings:ro
#   -e TIKTOKEN_ENCODINGS_BASE=/tiktoken_encodings
```

With that set, gpt-oss-20b started in ~240s and served completions. Note the
file must be named `o200k_base.tiktoken`, and setting the var **disables the
download fallback**, so a wrong path fails the same opaque way.

### vLLM itself is fine on this hardware

`--model Qwen/Qwen2.5-1.5B-Instruct` started in ~195s and served a completion,
with zero harmony mentions in the log — harmony loads only for gpt-oss. Nobody
should read this runbook as "vLLM does not work on the Spark". It does.

### ⛔ The real disqualifier: gpt-oss on vLLM is UNRELIABLE under concurrency

Once serving, concurrent requests fail with HTTP 500:

```
openai_harmony.HarmonyError: channel marker present but no channel value found in header
```

A harmony *parsing* failure, unrelated to the vocab one. Measured at ~23k-token
prompts on an idle box, four independent runs:

| concurrency | failures |
| --- | --- |
| c=1 | 0 |
| c=4 | 1/4, then 3/4, then 4/4 |
| c=8 | 4/8, then 3/8, then 3/8 |

**37-100% of requests fail under concurrency.** Ollama ran the identical
payloads at c=1, 4 and 8 with **zero** failures.

That ends the evaluation. Throughput is irrelevant when half the batch 500s,
and batch throughput was the entire case for vLLM. For reference the aggregate
numbers were close anyway (Ollama 65.6 tok/s at c=8 against vLLM's 102.2, and
vLLM's figure is inflated because it is computed over only the requests that
survived).

### What vLLM did demonstrably win

Its KV pool is bounded: raising `--max-num-seqs` from 4 to 32 cost **zero**
additional memory (98 GiB used either way), where Ollama preallocates per slot.
That advantage is real and unchanged — it is simply not purchasable while the
harmony parser drops requests.

### Revisit when

The channel-marker parse failures are fixed upstream. Re-test by running c=4
and c=8 against a served gpt-oss and counting 500s — not by benchmarking
throughput, which will look fine right up until you check the failure count.

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
