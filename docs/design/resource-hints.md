# 0.3.0 design: resource and configuration hints

Status: draft (2026-11-09). Target release: hayaoki 0.3.0.

0.2 measures cold starts in production (`require "hayaoki/insitu"`), and `hayaoki cold-start-report` aggregates the lines. The report shows how slow boot is and which phase is slow. It does not say whether more CPU or memory, or a platform setting, would help. 0.3.0 adds **hints** for that: short "likely" statements, each with the numbers behind it. They cover causes outside the app code (CPU quota, waiting, bootsnap setup, GC/memory, the Lambda Init limit). App-code causes stay with `hayaoki boot-report`.

A hint is never a certain claim. It names the numbers it used, how many lines it is based on, and the settings it cannot see.

---

## 0. Decisions at a glance

| # | Decision |
|---|---|
| H1 | Hints are computed by `cold-start-report` only. Insitu does not judge anything; it only records a few more facts. |
| H2 | The line schema stays `v: 1`. New keys are additive: a `limits` object, `proc.cpu_at_load_ms`, `phases_cpu_ms`. Old lines still work; rules that need a new key skip with a note. |
| H3 | The main signal is the **CPU share**: process CPU time / wall time over the same span. High share = CPU-bound; low share = waiting. It is normalized by the CPU quota when the quota is known. |
| H4 | Every rule needs at least 3 `ok` lines with a plausible start (except the Lambda timeout rule) and uses medians, not single lines. Resource rules only fire when `ready` p50 is at least 3 s. |
| H5 | Two levels: `likely` (strong signal, the suggested change has a clear effect) and `possible` (signal present, but the fix depends on a setting we cannot see). Plus `note` for facts that change how to read the report. |
| H6 | Wording names what cannot be seen from inside (min instances, CPU boost, concurrency, ...) and is written as a condition ("if startup CPU boost is not on, ..."). |
| H7 | No new platform API calls, no cloud credentials. Inputs are the lines plus the platform log lines that are already in the input (Lambda `REPORT` / `INIT_REPORT`). |

---

## 1. What the 0.2 measurements show

Seven cells were measured with 0.2.x (6 to 7 natural cold starts each, 20 min apart; raw data in `bench/cloud/results/`, gitignored). Settings: Cloud Run cpu=1, memory=1Gi, startup CPU boost on, min instances 0, concurrency 8. Lambda x86_64, container image with LWA.

CPU share below = `proc.cpu_ms / phases_ms.to_first_response`, per line, median (min–max). `proc.cpu_ms` is read at emit time (right after the first response), so both values cover the same span.

| Cell | ok (plausible start) | ready p50 / max | CPU share | GC time / CPU | RSS | bootsnap | Lambda Init max |
|---|---|---|---|---|---|---|---|
| CR gen1 minimal | 6 (5) | 4.9 s / 8.5 s | 0.74 (0.42–0.75) | 10% | 144 MB | on, cache in image | – |
| CR gen2 minimal | 6 (0) | from load: 6.5 s | n/a (start rejected) | 10% | 89 MB | on, cache in image | – |
| CR gen1 Redmine | 6 (6) | 20.3 s / 22.5 s | 0.60 (0.58–0.61) | 5% | 280 MB | off | – |
| Lambda minimal 1024 | 6 (6) | 1.8 s / 3.1 s | 0.81 (0.58–0.88) | 14% | 89 MB | on, cache in image | 3.1 s |
| Lambda minimal 2048 | 6 (6) | 1.9 s / 2.0 s | 0.85 (0.64–0.89) | 14% | 89 MB | on, cache in image | 2.1 s |
| Lambda Redmine 1024 | 5 (5) | 6.8 s / 9.3 s | 0.78 (0.57–0.89) | 9% | 230 MB | off | 10.0 s, 1 timeout |
| Lambda Redmine 2048 | 6 (6) | 5.6 s / 6.4 s | 0.89 (0.84–0.94) | 9% | 230 MB | off | 6.4 s |

What this tells us:

- **CR gen1 minimal**: 3.4–3.8 s of CPU per boot. Most lines spend about 75% of the wall time on CPU. The slow line (8.6 s to first response) used the same CPU (3.6 s) at a share of 0.42, so that one waited, but the median did not.
- **CR gen2 minimal**: processes start about 1.3 s after kernel boot, then are frozen until a request comes, so `pre_load` is minutes to hours and the start is rejected (0.2.1 shows "(from load)" rows). `proc.cpu_ms` includes the CPU used before the freeze, so no share can be computed from 0.2 lines. From load to ready is 6.5 s, against 3.8 s on gen1. `cpu_at_load_ms` (§2.2) is what makes this cell readable.
- **CR gen1 Redmine**: initialize 11.3 s and bundler_require 4.2 s (p50). The image has no bootsnap. Share 0.60, the same in every line: neither clearly CPU-bound nor waiting. On gen1, gVisor work for system calls (file opens, stats) is probably not counted as process CPU, so file-heavy boot without bootsnap looks partly like waiting.
- **Lambda**: 1024 MB and 2048 MB give the same result for minimal (1.8 vs 1.9 s). For Redmine, 2048 MB is faster (6.8 → 5.6 s p50) with the same CPU time (about 5.3 s), so at 1024 MB the boot was probably short of CPU. Lambda's documented CPU is proportional to memory (1 vCPU at 1769 MB [L8]), which gives 0.58 vCPU at 1024 MB. But the measured share at 1024 MB is 0.78, above that nominal value. CPU during Init may not follow the nominal ratio; the rules must not depend on it exactly (§3, Q2).
- **Lambda Redmine 1024**: one Init hit the 10 s limit (`INIT_REPORT ... Status: timeout`) on the first invoke after a new image. That cold start has no hayaoki line (5 lines for 6 inits). The slowest line that was written took 9.3 s to ready.
- No cell is close to its memory limit (max RSS 280 MB of 1 GiB), and GC is 5–14% of CPU. The GC and memory rules should stay quiet on all of these.

---

## 2. Signals

### 2.1 Already in the v1 line

| Signal | Field | Used by |
|---|---|---|
| Wall time to ready / first response | `phases_ms.to_ready`, `to_first_response`, `pre_load` | all |
| Process CPU time at emit | `proc.cpu_ms` | cpu_bound, wait_dominated |
| GC | `proc.gc_count`, `proc.gc_time_ms` | gc_pressure |
| RSS at emit | `proc.rss_kb` | memory_near_limit |
| bootsnap | `runtime.bootsnap`, `runtime.bootsnap_cache` | bootsnap rules |
| Lambda memory size, init type | `platform.memory_mb`, `platform.init_type` | lambda rules, quota for Lambda |
| Start not believable | `start_rejected`, `pre_load` > 600 s | prestarted_process, gating |
| Sandbox age | `proc.uptime_ms` (on Cloud Run ≈ `to_first_response`: one kernel per instance) | not used by rules; shown as evidence |

Platform lines already parsed by the reader: Lambda `Init Duration`. New in the reader: `INIT_REPORT ... Status: <status>` counts (Phase, Status). No change to the line for this.

### 2.2 New fields (additive, schema stays v1)

```json
"limits": {"cgroup": "v2", "cpu_quota": 2.0, "nproc": 2, "mem_max_mb": 1024, "sandbox": "gvisor"},
"proc": {"cpu_at_load_ms": 410, ...},
"phases_cpu_ms": {"bundler_require": 520, "initialize": 2900, "load_to_ready": 3420, "load_to_first_response": 3500}
```

| Field | Source | When read | Cost | Notes |
|---|---|---|---|---|
| `limits.cgroup` | which of `/sys/fs/cgroup/cpu.max` (v2) or `/sys/fs/cgroup/cpu/cpu.cfs_quota_us` (v1) exists | at load | 1–2 `File.file?` | `null` when neither |
| `limits.cpu_quota` | v2 `cpu.max` (`"200000 100000"` → 2.0; `"max ..."` → null); v1 `cfs_quota_us / cfs_period_us` (-1 → null) | at load | 1–2 small reads | read at load because startup boost may change it later; whether gen1/gen2 expose it is unverified (step 1) |
| `limits.nproc` | `Etc.nprocessors` (honours affinity) | at load | 1 syscall | not a quota; a hint only |
| `limits.mem_max_mb` | v2 `memory.max` / v1 `memory.limit_in_bytes`; "max" or a value ≥ 2^60 → null | at emit | 1 read | Lambda falls back to `platform.memory_mb` in the report |
| `limits.sandbox` | `"gvisor"` when `/proc/version` matches the gVisor fake kernel string; else null | at load | 1 read | heuristic; the string itself is never logged |
| `proc.cpu_at_load_ms` | `Clock.cpu_ms` at the `loaded` mark (null in a forked child) | at load | ~1 µs | lets the report compute CPU share from load (gen2, rejected starts) |
| `phases_cpu_ms` | `Clock.cpu_ms` at the bundler / initialize / ready / first-response marks | at each mark | ~1 µs × 5 | like `phases_ms`: duplicates derivable data so log queries need no math |

Overhead: all reads together are well under 1 ms, done once per process, inside the 0.2 budget (phase2.md §2.3). Every reader returns nil on any error and never raises (same pattern as `ProcFS`).

Privacy: only numbers and fixed tokens (`v1`/`v2`/`gvisor`). No paths, no kernel version string, no hostnames, no env values. `phases_cpu_ms` is process CPU time, which says nothing about requests or users.

Not added: per-thread CPU, `/proc/pressure/*` (PSI; often missing in gVisor and Firecracker, and the cost of reading it at each mark is not worth it for 0.3), `memory.peak` (newer kernels only; candidate for later), other env flags. The one exception is `platform.lwa_async_init` (Lambda only, boolean, true only when the value is `"true"`; the value is never logged; Q3).

---

## 3. Rules

Shared definitions:

- `ok_p` = lines with `status == "ok"` and a plausible start (`Stats.implausible_start?` false, no `start_rejected`).
- `share(line)` = `cpu_ms / to_first_response` on `ok_p` lines. With the new fields, also `share_from_load = (cpu_ms - cpu_at_load_ms) / (to_first_response - pre_load)`, which works on all `ok` lines, rejected starts included. When `cpu_at_load_ms` is present, the rules use `share_from_load`.
- `quota` = `limits.cpu_quota` (median over lines); on Lambda without it, `memory_mb / 1769` (nominal, marked "nominal" in the evidence).
- `busy` = `share / min(quota, 1.0)`, clamped to 1.0. Boot is mostly one Ruby thread, so one vCPU is the most it can use. A quota below 1 makes throttled time look like waiting; `busy` corrects for that.
- Gate `G_ready`: `ready` p50 ≥ 3000 ms. Below that, resource hints are not worth the noise (Lambda minimal at 1.8 s is the reference).
- Gate `G_n`: at least 3 lines in the set the rule reads. Otherwise the rule emits nothing, and the report prints one line: "hints need at least 3 ok cold starts (have N)".
- Aggregation: medians over lines, max and count where noted. The evidence always carries `n`.
- Mixed configs: if the set has more than one value of `platform.revision`, `platform.memory_mb`, `limits.cpu_quota` or `runtime.bootsnap`, every hint gets `mixed: true` and the text adds "lines come from different configurations; try --group-by revision" (Q4).

| id | Inputs | Fires when | Level |
|---|---|---|---|
| `cpu_bound_boot` | share, quota, ready | G_n, G_ready, median `busy` ≥ 0.70 | `likely` if quota < 1.0; else `possible` |
| `wait_dominated_boot` | share, quota, ready, sandbox | G_n, G_ready, median `busy` ≤ 0.50 | `likely` |
| `bootsnap_off` | `runtime.bootsnap` | G_n, `bootsnap == false` in ≥ half of `ok` lines | `likely` |
| `bootsnap_cache_cold` | `runtime.bootsnap`, `bootsnap_cache` | G_n, bootsnap on and `bootsnap_cache == false` in ≥ half (null lines ignored) | `likely` |
| `gc_pressure` | `gc_time_ms`, `cpu_ms`, ready | G_n, G_ready, median `gc_time_ms / cpu_ms` ≥ 0.20 | `possible` |
| `memory_near_limit` | `rss_kb`, `mem_max_mb` or `memory_mb` | G_n, median `rss / limit` ≥ 0.80, or any line ≥ 0.90 | `likely` |
| `lambda_init_near_limit` | Init Duration, INIT_REPORT status, ready | Lambda; any `Status: timeout` (n ≥ 1 is enough); or G_n and p90 of max(Init Duration, to_ready) ≥ 7000 ms | `likely` |
| `prestarted_process` | `start_rejected`, `pre_load` | ≥ half of `ok` lines have a rejected or implausible start | `note` |

Wording (text output; `{}` are evidence values; the trailing "Cannot see" part comes from §4):

- **cpu_bound_boot**: "Boot was likely CPU-bound: the process was on CPU {busy}% of the time to first response (median of {n}; CPU {cpu_p50} s of {wall_p50} s; quota {quota} vCPU{ nominal})." Then by case:
  - Lambda, quota < 1: "More memory gives more CPU and will likely shorten Init. Try {next memory step} MB."
  - Cloud Run, quota < 1: "More CPU will likely shorten boot: cpu=1 or more, and startup CPU boost."
  - quota ≥ 1 or unknown: "Ruby boot runs mostly on one thread, so more than one vCPU probably helps little. If startup CPU boost is not on, turn it on. Otherwise the remaining fix is less CPU work at boot: see `hayaoki boot-report`."
  - False positives: `cpu_ms` includes the first request and (without `cpu_at_load_ms`) the time before load; background threads can push share up; with an unknown quota a throttled CPU is not visible; lines with `worker: true` (forked child) have no `cpu_at_load_ms` and the old share is wrong there (the child's CPU clock restarts), so rules skip `worker: true` lines without it.
- **wait_dominated_boot**: "Boot likely spent most of its time waiting, not computing: on CPU {busy}% of the time (median of {n}). More CPU is unlikely to help. Likely causes: file IO (no bootsnap cache, many small files, lazily pulled image layers), network calls during boot (DB, secrets, HTTP in initializers), or CPU throttled before the first request." Cloud Run adds: "Try the other execution environment (gen1/gen2); file IO cost differs between them." With `sandbox: gvisor`: "gVisor system-call work is probably not counted as process CPU."
  - False positives: an unknown quota below 1 vCPU looks like waiting (hence `busy`, and the quota-unknown text says so); a frozen-then-thawed process on gen2 without `cpu_at_load_ms` (the rule skips rejected starts in that case); lines with `worker: true` (forked child) have no `cpu_at_load_ms` and the old share is wrong there, so the rule skips them.
- **bootsnap_off**: "bootsnap was not loaded in {k} of {n} cold starts. With bootsnap and a cache built into the image, boot likely skips load-path scans and recompiles. Measure the gain with `hayaoki boot-report`." No savings estimate: the lab number does not carry over to the platform.
- **bootsnap_cache_cold**: "bootsnap is on, but its cache directory did not exist at boot in {k} of {n} cold starts, so each cold start likely rebuilds it. Precompile it in the image (`bootsnap precompile`) and check that the cache dir at runtime is the one built into the image." On Lambda add: "the image filesystem is read-only; a cache written at runtime goes to /tmp and is lost with the environment."
  - False positive: `bootsnap_cache` is null when bootsnap loaded before hayaoki; those lines are ignored.
- **gc_pressure**: "GC took {pct}% of boot CPU (median {gc_ms} ms of {cpu_ms} ms, {gc_count} GCs). Heap tuning (`RUBY_GC_HEAP_INIT_SLOTS` and related) or more memory may reduce it." Possible only: GC share also rises when total CPU is small.
- **memory_near_limit**: "RSS at first response was {rss} MB of {limit} MB ({pct}%). The instance is likely close to its memory limit; GC work and OOM restarts rise near it. Consider more memory." RSS at emit is not the peak, so this can miss short peaks (false negative, not false positive).
- **lambda_init_near_limit**: "Init likely ran into the 10 s Lambda limit: {timeouts} timeout(s); slowest Init {max} s, p90 {p90} s (n={n}). A timed-out Init is retried within the first invoke, and that cold start has no hayaoki line ({lines} lines for {inits} Init reports). Options: more memory (more CPU during Init); `AWS_LWA_ASYNC_INIT=true` so LWA ends Init before the limit and finishes the readiness check in the first invoke [L7]; bootsnap with its cache in the image." If only a timeout and no near-limit p90: add "a single timeout right after a deploy can be the first pull of a new image; check whether it repeats."
- **prestarted_process**: "In {k} of {n} lines the process started long before hayaoki loaded (pre_load {p50}). The platform probably started the process ahead of the request and froze or throttled it (Cloud Run gen2 does this). Read the \"(from load)\" rows; the time before load is not user-visible boot."

### 3.1 Which hint each measured cell gets

With 0.2 lines (new fields missing) and the thresholds above:

| Cell | busy (median) | Hints |
|---|---|---|
| CR gen1 minimal | 0.74 (quota unknown → 1.0) | `cpu_bound_boot` possible ("probably helps little ... boost ... boot-report"). Close to 0.70; Q1 |
| CR gen2 minimal | n/a (all starts rejected) | `prestarted_process` note. With `cpu_at_load_ms`: expected `wait_dominated_boot` (6.5 s from load vs about 3.8 s on gen1 for the same app); to verify in the re-measurement |
| CR gen1 Redmine | 0.60 | `bootsnap_off` likely. No CPU hint: between 0.50 and 0.70 |
| Lambda minimal 1024 | 0.81 | none (ready p50 1.8 s < 3 s). Matches 1024 ≈ 2048 |
| Lambda minimal 2048 | 0.85 | none (gate) |
| Lambda Redmine 1024 | 1.0 (0.78 / nominal 0.58, clamped) | `lambda_init_near_limit` likely (1 timeout; Init p90 10.0 s, to_ready p90 9.3 s); `cpu_bound_boot` likely ("try 2048 MB"; the 2048 cell was 1.2 s faster at p50); `bootsnap_off` likely |
| Lambda Redmine 2048 | 0.77 (0.89 / nominal 1.16) | `cpu_bound_boot` possible (more memory probably helps little; less CPU work); `bootsnap_off` likely. Init max 6.4 s stays under 7 s (Q7) |

The rules fire on Redmine (no bootsnap, near the Lambda limit) and on nothing in the Lambda minimal cells, where changing memory made no difference. That is the intended calibration. The gen1 minimal `cpu_bound_boot` is borderline; it is `possible` and its wording mostly points away from adding vCPU.

---

## 4. What cannot be seen from inside

| Setting | Visible? | How the wording handles it |
|---|---|---|
| Cloud Run startup CPU boost | Only indirectly, if `cpu.max` at load shows more than the configured CPU (and we do not know the configured CPU) | "If startup CPU boost is not on, turn it on" |
| Cloud Run CPU allocation (request-based / always on) | No | wait / prestarted hints mention "throttled before the request" as one possible cause |
| Min instances, max instances, concurrency | No. Proactive starts are guessed from `idle` (0.2) | Hints are about boot length, not about how often users hit it; text says "these hints do not cover how often users hit a cold start (min instances)" once per report |
| Execution environment gen1/gen2 | gen1 via `limits.sandbox` (heuristic); gen2 only by elimination | Suggest comparing both; never state which one is in use unless `sandbox` is set |
| Lambda provisioned concurrency | Yes, `platform.init_type` | Lines with `provisioned-concurrency` are excluded from the Lambda limit rule (Init is not user-facing there) |
| `AWS_LWA_ASYNC_INIT` | Yes, `platform.lwa_async_init` (boolean, true only when the value is "true"; the value is never logged) | "If false, consider ..." (Q3) |
| LWA readiness settings | No (env values are never logged) | Mentioned as possible causes only |
| Image size, layer caching, region, cold image pull | No | Mentioned only as possible causes in the wait and timeout texts |

Each hint's JSON carries `cannot_see: [...]` with the relevant settings, and the text prints them as one "Cannot see:" line.

---

## 5. Output

Text: a `Hints` section after the summary (per group when `--group-by` is used), ordered by level then rule id:

```
Hints (likely causes outside app code; based on 5 ok cold starts with a plausible start)
  likely    lambda_init_near_limit  Init likely ran into the 10 s Lambda limit: 1 timeout(s); slowest Init 10.0 s, to_ready p90 9.3 s (n=5). ...
  likely    cpu_bound_boot          Boot was likely CPU-bound: the process was on CPU 100% of the time ... quota 0.58 vCPU nominal). ...
  likely    bootsnap_off            bootsnap was not loaded in 5 of 5 cold starts. ...
            Cannot see: AWS_LWA_ASYNC_INIT, provisioned concurrency outside these lines
```

`--no-hints` turns the section off. With no hint: "Hints: none (n=6)". With too few lines: the `G_n` line.

JSON (report `v` stays 1; additive key inside each summary):

```json
"hints": [
  {"id": "cpu_bound_boot", "level": "likely", "n": 5, "mixed": false,
   "evidence": {"busy_p50": 1.0, "share_p50": 0.78, "cpu_ms_p50": 5420, "wall_ms_p50": 6991,
                "quota": 0.58, "quota_source": "nominal_memory"},
   "message": "Boot was likely CPU-bound: ...",
   "cannot_see": ["startup_cpu_boost"]}
]
```

Evidence keys are stable per rule and documented in the README; `message` is fixed text with numbers only, as in the line (no IDs, names or routes).

---

## 6. Tests

- Insitu readers (`test/insitu/limits_test.rb`): fixture strings for `cpu.max` (`"max 100000"`, `"200000 100000"`, garbage), v1 quota/period (`-1`, `50000/100000`), `memory.max` (`"max"`, bytes, sentinel), a gVisor and a normal `/proc/version`, missing files. All pure functions with injectable `src`, as `ProcFS`.
- Emitter: `limits`, `cpu_at_load_ms` and `phases_cpu_ms` present and numeric on Linux, nil-safe elsewhere; old keys unchanged (schema test from 0.2 still passes).
- Reader: `INIT_REPORT ... Status: timeout` and `Status: error` lines counted, in plain text, CloudWatch export and JSON-array input.
- Rules (`test/cold_start_report/hints_test.rb`): a helper builds synthetic lines (`line(platform: :lambda, memory_mb: 1024, ready: 6800, cpu: 5400, bootsnap: false)`) with placeholder values only (service `svc`, revision `svc-00001-abc`, function `fn`). For each rule: fires just over the threshold, silent just under, silent below `G_n` / `G_ready`, ignores implausible starts, `mixed` set when revisions differ.
- Calibration test: synthetic sets that copy the per-cell medians of §1 (numbers only) must produce exactly the hints in §3.1. If a threshold changes, this table and the test change together.
- Formatters: text and JSON for one set with three hints, one with none, one under `G_n`.
- No real data in fixtures: no IDs, URLs, account numbers, emails or log stream names. A test greps the fixture dir for patterns like long hex or 12-digit numbers.

---

## 7. Scope

0.3.0: §2.2 fields, reader `INIT_REPORT` status, the 8 rules, text/JSON output, README section, re-measurement of the CR cells and Lambda Redmine with the new fields (the user runs it).

Deferred: hints that compare two groups (for example "2048 MB was 1.2 s faster than 1024 MB" from one `--group-by memory_mb` run; candidate for 0.3.x), PSI, `memory.peak`, Cloud Run / Lambda API lookups of the real settings, a Lambda Telemetry API extension.

---

## 8. Implementation order (commit-sized)

| # | Step | Files | Delegate |
|---|---|---|---|
| 1 | `Insitu::Limits` readers (cgroup v1/v2 cpu and memory, nproc, gVisor check); pure functions, fixture tests. Run a one-off check in a CR gen1 and gen2 container and in Lambda that the files exist (user runs) | `lib/hayaoki/insitu/limits.rb`, test | sonnet; user runs the check |
| 2 | CPU at marks: `State` records `Clock.cpu_ms` next to each mark; emitter writes `cpu_at_load_ms`, `phases_cpu_ms`, `limits`; overhead bench re-run | `insitu/{state,hooks,middleware,emitter}.rb` | sonnet impl, **fable** review |
| 3 | Reader: `INIT_REPORT` phase/status counts into the result | `cold_start_report/reader.rb`, `runner.rb` | sonnet |
| 4 | Hints frame: `ColdStartReport::Hints` (shared definitions of §3: `ok_p`, share, quota, busy, gates, mixed), `Hint` struct, rule registry | `cold_start_report/hints.rb` | **fable** (spec is §3) |
| 5 | Config rules: `bootsnap_off`, `bootsnap_cache_cold`, `prestarted_process`, `lambda_init_near_limit` | `cold_start_report/hints/*.rb`, tests | sonnet |
| 6 | Resource rules: `cpu_bound_boot`, `wait_dominated_boot`, `gc_pressure`, `memory_near_limit`; calibration test of §3.1 | same | **fable** (thresholds), sonnet (tests) |
| 7 | Text/JSON output, `--no-hints` | `formatters/{text,json}.rb`, `cli.rb` | sonnet |
| 8 | Run the report on the local `bench/cloud/results` cells; compare with §3.1; adjust thresholds only with a note here | – | **fable** |
| 9 | Re-measure with 0.3 lines (CR gen1/gen2 minimal + Redmine, Lambda Redmine 1024/2048; Q5), update §1 and §3.1 | `bench/cloud/*` | user runs; sonnet updates the doc |
| 10 | README section, CHANGELOG, version 0.3.0, review | `README.md`, `CHANGELOG.md` | sonnet + **fable** review |

---

## 9. Decisions (2026-11-09)

- Scope split: **0.3.0** ships only hints computable from fields 0.2 lines already carry, verifiable on local data without cloud work: `bootsnap_off`, `bootsnap_cache_cold`, `prestarted_process`, `lambda_init_near_limit`, `gc_pressure` (steps 3, 4, 5, 7 and the `gc_pressure` part of 6, then 10). **0.4.0** adds `limits`, `cpu_at_load_ms` / `phases_cpu_ms`, `cpu_bound_boot`, `wait_dominated_boot`, `memory_near_limit` together with the cloud re-measurement (steps 1, 2, rest of 6, 8, 9).
- Q1: keep 0.70 / 0.50 and 3 s; revisit with 0.4 data.
- Q2: Lambda uses the nominal `memory_mb / 1769` quota when cgroup gives nothing; wording says "estimate".
- Q3: yes, record a boolean for `AWS_LWA_ASYNC_INIT` presence (not its value).
- Q4: flag only (`mixed: true`); users split with `--group-by`.
- Q5: decide after the 0.4 implementation.
- Q6: hints on by default in text output; `--no-hints` turns them off.
- Q7: 7 s.

---

## Sources

- phase2.md Sources [L1]–[L7], [C1]–[C3] (Init 10 s limit and INIT_REPORT; LWA async init; Cloud Run startup CPU boost and CPU limits).
- [L8] Lambda memory and CPU (CPU proportional to memory; 1 vCPU at 1,769 MB): https://docs.aws.amazon.com/lambda/latest/dg/configuration-memory.html — to verify that the figure is current.
- To verify: whether Cloud Run gen1 (gVisor) and gen2 expose `/sys/fs/cgroup/cpu.max` and `memory.max` to the container; the gVisor `/proc/version` string; whether Lambda Init CPU follows the memory ratio (the 1024 MB share of 0.78 suggests it does not).
