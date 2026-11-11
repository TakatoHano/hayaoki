# 0.3.0 design: resource and configuration hints

Status: draft (2026-11-09). Target release: hayaoki 0.3.0.

0.2 measures cold starts in production (`require "hayaoki/insitu"`), and `hayaoki cold-start-report` aggregates the lines. The report shows how slow boot is and which phase is slow. It does not say whether more CPU or memory, or a platform setting, would help. 0.3.0 adds **hints** for that: short "likely" statements, each with the numbers behind it. They cover causes outside the app code (CPU quota, waiting, bootsnap setup, GC/memory, the Lambda Init limit). App-code causes stay with `hayaoki boot-report`.

A hint is never a certain claim. It names the numbers it used, how many lines it is based on, and the settings it cannot see.

---

## 0. Decisions at a glance

| # | Decision |
|---|---|
| H1 | Hints are computed by `cold-start-report` only. Insitu does not judge anything; it only records a few more facts. |
| H2 | The line schema stays `v: 1`. New keys are additive: a `limits` object, `proc.cpu_at_load_ms`, `phases_cpu_ms`, and later the run-queue wait (§2.2.1), the counters of §2.2.2 and the opt-in `sampler` object (§2.2.3). Old lines still work; rules that need a new key skip with a note. |
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

### 1.1 Re-measurement with 0.3.1 lines (2026-11-10)

Same settings, new GCP project, hayaoki 0.3.1 (adds `limits`, `proc.cpu_at_load_ms`, `phases_cpu_ms`). 6 natural cold starts per cell, 20 min apart. Lambda minimal was not re-measured.

CPU share here is from load: `(cpu_ms - cpu_at_load_ms) / (to_first_response - pre_load)`; for gen2 (start rejected) the wall time is `marks_ms.first_response_end - marks_ms.loaded`.

| Cell | ok (plausible start) | ready p50 | CPU share from load, median | `limits` | RSS p50 | GC / CPU |
|---|---|---|---|---|---|---|
| CR gen1 minimal | 6 (6) | 5.7 s | 0.75 | cgroup v1, cpu_quota 2, mem 1024, sandbox gvisor | 144 MB | 6% |
| CR gen2 minimal | 6 (0) | n/a (start rejected) | 0.29 (5 lines 0.25–0.29; 1 line 0.77) | cgroup v1, cpu_quota 1.97, mem 1024, sandbox null | 89 MB | 9% |
| CR gen1 Redmine | 6 (6) | 13.6 s | 0.59 | as gen1 minimal | 280 MB | 6% |
| Lambda Redmine 1024 | 5 (5) | 5.8 s | 0.92 | all null (no cgroup files) | 230 MB | 9% |
| Lambda Redmine 2048 | 6 (6) | 5.7 s | 0.94 | all null | 229 MB | 9% |

What changed in our understanding:

- **The new fields work.** gen1 shows `sandbox: gvisor`, gen2 does not, so the heuristic separates them. Both expose cgroup v1 files. `cpu_quota` is 2 at load on a cpu=1 service: startup CPU boost is visible from inside (§4).
- **gen2 waits.** From load, gen2 is on CPU only about 29% of the time, against 75% on gen1 for the same image. `cpu_at_load_ms` made this cell readable, as expected in §3.1. The one 0.77 line is probably the instance that started at deploy time.
- **Lambda Init does not follow the memory ratio.** At 1024 MB the share is 0.92, above the nominal 0.58 vCPU, which a quota would not allow. 2048 MB is not faster (5.8 vs 5.7 s; the 0.2 run showed 6.8 vs 5.6 s, which was probably runner variance). This matches reports that Init gets host CPU independent of the memory setting for its first 10 s ([L9], [L10]). Not in the official Lambda docs.
- Cloud Run run-to-run variance is large: gen1 minimal ready ranged from 5.3 s to 14.2 s within the 6 lines of this run (p50 5.7 s; 4.9 s in the 0.2 run), with the same image and settings. Hints use shares and medians, not absolute times, partly for this reason.
- Memory and GC stay far from the thresholds (RSS ≤ 280 MB of 1024 MB; GC 6–9%).

### 1.2 Run-queue wait in 0.4.1 / 0.4.2 lines (2026-11-11)

Two cells were measured again with the run-queue fields of §2.2.1 (6 natural cold starts each; same settings as §1.1). "Off CPU" is wall time from load to first response minus process CPU over the same span. "Run queue" is `main_thread_runq_wait_ms - main_thread_runq_wait_at_load_ms`.

| Cell | Lines | Load to first response | CPU share from load | CPU | Off CPU | Run queue | Run queue / off CPU |
|---|---|---|---|---|---|---|---|
| CR gen2 minimal (0.4.1), slow lines | 4 | 6.2–6.7 s | 0.25–0.27 | 1.6–1.7 s | 4.6–5.1 s | 1–2 ms | 0.00 |
| CR gen2 minimal (0.4.1), fast lines | 2 | 1.6–1.7 s | 0.84–0.87 | 1.3–1.5 s | 0.2–0.3 s | 1 ms | 0.00–0.01 |
| Lambda Redmine 1024 (0.4.2) | 6 | 4.2–5.7 s | 0.84–0.92 (median 0.91) | 3.7–4.9 s | 0.4–0.9 s | 75–144 ms | 0.09–0.29 (median 0.21) |

- **Both platforms expose `/proc/self/schedstat` with real values.** gen2 (`cpu_quota` 2.09 at load) and Lambda both report a counter that moves. Cloud Run gen1 lines of 0.4.1 carry null in both fields: gVisor does not provide the file.
- **gen2 does not wait for a CPU.** The slow lines are off CPU for about 4.8 s and the main thread spent 1–2 ms of that in the run queue. A CPU quota that throttles the process would show up in this counter, so the earlier guess "CPU throttled before the first request" does not hold for this cell. The CPU time is the same in fast and slow lines (1.3–1.7 s); the slow lines stretch `pre_bundler`, `app_config` and `initialize`, the phases that mostly `require` files. What is left is file IO, or the host not running the VM (which the guest's run queue cannot see; §2.2.2).
- **Lambda waits a little, and partly for a CPU.** About 450 ms off CPU per boot, of which 75–144 ms in the run queue. `cpu_bound_boot` fires there, so the split of §3.2 is not applied. The 0.21 median shows that an ordinary CPU-bound boot can have a fifth of its small off-CPU time in the run queue; the "not waiting for a CPU" threshold sits at that value, not above it.

### 1.3 Counters in 0.4.3 lines (2026-11-11)

The same cells again with the counters of §2.2.2 (natural cold starts, `ok` lines only). Counters are emit − load.

| Cell | Lines | Load to first response | CPU share from load | Off CPU | Run queue | `majflt` | `io_read_bytes` | `io_rchar` | Steal | PSI |
|---|---|---|---|---|---|---|---|---|---|---|
| CR gen2 minimal, slow lines | 4 | 6.3–6.8 s | 0.24–0.31 | 4.6–5.0 s | 0–4 ms | 126 | 30.4 MB | 8.4 MB | 0 | null |
| CR gen2 minimal, fast lines | 2 | 2.1–2.4 s | 0.79–0.80 | 0.43–0.47 s | 1 ms | 126 | 30.4 MB | 8.4 MB | 0 | null |
| Lambda Redmine 1024 | 6 | 4.3–6.2 s | 0.82–0.91 | 0.46–1.1 s | 85–154 ms | 2811–2812 | 39.2 MB | 21.8 MB | 10–50 ms (2 CPUs) | null |
| CR gen1 minimal (gVisor) | 2 | 6.2–6.8 s (2.5 s of it idle before the first request) | 0.29–0.32 | 4.4–4.7 s | null | 0 | 0 | 8.4 MB | 0 | null |

- **gen2 is bimodal again, and the counters are the same in both modes.** Fast and slow lines have the same 126 major faults, the same 30.4 MB read from storage and the same 8.4 MB passed to read calls. The slow lines add 4.2–4.6 s off CPU in the phases that mostly `require` files (`pre_bundler` 0.8 s → 2.3–3.1 s). So the slow boots did the same amount of IO. Either each IO took longer (a cold image cache on the host side: about 37 ms per major fault instead of about 3 ms, if the faults carry all of it), or the instance did not run for part of the time. The counters are sizes and cannot tell these apart.
- **PSI is missing on every cell** (the files do not exist), so the PSI sentence of §3.2 and the remainder (`unaccounted_ms_p50`) never apply on these platforms.
- **Steal is real on Lambda** (10–50 ms over 2 CPUs) and 0 on gen2. A 0 on gen2 does not show that the host ran the VM all the time; the host may not report steal to the guest.
- **gVisor reports 0** for `majflt`, `io_read_bytes` and steal, and has no run-queue file (already handled in §3.2).

What is missing is a time, per thread, split by what the thread was doing. That is §2.2.3.

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
"proc": {"cpu_at_load_ms": 410,
         "main_thread_runq_wait_ms": 14, "main_thread_runq_wait_at_load_ms": 2,
         "majflt": 850, "majflt_at_load": 10, "io_read_bytes": 85983232, "io_read_bytes_at_load": 1048576,
         "io_rchar": 96000000, "io_rchar_at_load": 2400000, "steal_ms": 140, "steal_at_load_ms": 100,
         "psi_io_some_ms": 450, "psi_io_some_at_load_ms": 50, "psi_cpu_some_ms": 9, "psi_cpu_some_at_load_ms": 5, ...},
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
| `proc.main_thread_runq_wait_at_load_ms` | field 2 of `/proc/self/schedstat` (ns runnable but not on a CPU) at the `loaded` mark; null in a forked child | at load | 1 small read | issue #12; see §2.2.1 |
| `proc.main_thread_runq_wait_ms` | same counter at emit | at emit | 1 small read | null when the file is missing (non-Linux, kernel without `CONFIG_SCHED_INFO`, gVisor) |
| `proc.majflt_at_load`, `proc.majflt` | field 12 of `/proc/self/stat`: major page faults of the process (all threads), a count | at load, at emit | 1 small read each | §2.2.2 |
| `proc.io_read_bytes_at_load`, `proc.io_read_bytes` | `read_bytes` of `/proc/self/io`, bytes | at load, at emit | 1 small read each (shared with `io_rchar`) | 0 on overlay / FUSE / virtiofs does not mean "no IO"; null when the file cannot be read |
| `proc.io_rchar_at_load`, `proc.io_rchar` | `rchar` of `/proc/self/io`, bytes | same read | – | bytes passed to read-type system calls; context for a `read_bytes` of 0 |
| `proc.steal_at_load_ms`, `proc.steal_ms` | field 8 (steal) of the first `cpu` line of `/proc/stat`, USER_HZ ticks converted to ms | at load, at emit | 1 read each | system-wide and summed over CPUs, not this process |
| `proc.psi_io_some_at_load_ms`, `proc.psi_io_some_ms` | `some ... total=` (µs) of `/proc/pressure/io`, in ms | at load, at emit | 1 small read each | system-wide; null without PSI |
| `proc.psi_cpu_some_at_load_ms`, `proc.psi_cpu_some_ms` | same for `/proc/pressure/cpu` | at load, at emit | 1 small read each | system-wide; null without PSI |

Overhead: all reads together are well under 1 ms, done once per process at load and once at emit, inside the 0.2 budget (phase2.md §2.3). No read happens at the other marks. Every reader returns nil on any error and never raises (same pattern as `ProcFS`).

#### 2.2.1 Run-queue wait: main thread only (issue #12, 2026-11-10)

The CPU rules cannot tell two kinds of non-CPU time apart: runnable but not scheduled (CPU quota throttling, host contention) and blocked (file IO, slow under gVisor; network). `/proc/self/schedstat` field 2 counts the first kind, so the two fields above let a later check split them.

Scope decision: `/proc/self/schedstat` is `/proc/<tgid>/schedstat`, the thread-group leader's own counter, while `proc.cpu_ms` is `CLOCK_PROCESS_CPUTIME_ID` over all threads. The options were (a) main thread at load and at emit, (b) a sum over `/proc/self/task/*/schedstat` at emit, (c) an extra read at `initialize_end`. We chose (a) and named the fields after it:

- Boot (`loaded` to `initialize_end`) runs on the main thread, so its wait is covered exactly. After `initialize_end` the main thread in a Puma process starts the server and then sleeps, so its counter barely moves: the difference emit minus load is in practice the boot wait. The first request runs on a server thread and is not in it; in a single-threaded server it is.
- (b) costs one read per thread (Puma: 5 to 16 plus Ruby's timer thread), loses threads that exited, and at load there is only one thread anyway. (c) adds a `/proc` read to a mark that today costs one clock call, for a value that (a) already approximates.
- So `main_thread_runq_wait_ms - main_thread_runq_wait_at_load_ms` is comparable with `phases_cpu_ms.load_to_ready` and the wall time `to_ready - pre_load` (or `marks_ms.initialize_end - marks_ms.loaded`), not one to one with `cpu_ms`, which includes the server threads. The report shows the median as evidence (`main_thread_runq_wait_ms_p50`) on the two CPU hints, and `wait_dominated_boot` uses it for the split of §3.2.
- Forked child: the child's schedstat starts at zero like its CPU clock, so `*_at_load_ms` is null there (same rule as `cpu_at_load_ms`) and `main_thread_runq_wait_ms` covers the child's main thread since fork.

Cloud check before any rule uses it: do Cloud Run gen1 (gVisor), gen2 and Lambda (Firecracker) expose `/proc/self/schedstat` with real values? gVisor implements its own `/proc`; it may omit the file (then both fields are null) or report zeros. On gen2 and Lambda the kernel needs `CONFIG_SCHED_INFO`. A value that stays at zero over a 6 s boot on a cell with a known quota below 1 vCPU would mean the counter is not trustworthy there. Answered in §1.2: gen2 and Lambda report real values, gen1 has no file. A cell with a known quota below 1 vCPU has not been measured yet.

Smaller change shipped with the fields: when `cpu_bound_boot` fires on the median but some lines are at or under `WAIT_BUSY`, the text adds "k of n lines waited instead: on CPU 50% of the time or less" and the evidence carries `waited_lines` (gen1 minimal: 2 of 6).

#### 2.2.2 Counters behind the time off CPU (issue #12, 2026-11-11)

The run-queue wait says whether boot waited for a CPU. When it did not, the line so far gave no number for what it waited on. Six counters, from five reads (`/proc/self/stat`, `/proc/self/io`, `/proc/stat`, `/proc/pressure/io`, `/proc/pressure/cpu`), are read at load and again at emit, in the same way as the run-queue wait; the report uses emit minus load. Each is null on its own when its file or field is missing or unreadable, and no reader raises.

| Counter | What it measures | Scope | Limits |
|---|---|---|---|
| `majflt` | page faults that had to wait for storage: pages of mapped files (the Ruby binary, shared libraries, bootsnap's mmap'd cache) that were not in the page cache, such as image pages fetched on first use | process, all threads | a count, not a time. Plain `read` calls on a cold file do not count here |
| `io_read_bytes` | bytes the process caused to be fetched from a block device | process | stays 0 when the files live on overlay over a non-block backend, FUSE or virtiofs. 0 does not mean "no IO". `/proc/self/io` is denied in some sandboxes |
| `io_rchar` | bytes passed to `read`-type system calls, page-cache hits included | process | says how much was read, not whether it waited. No mmap |
| `steal_ms` | time the hypervisor ran something else while a vCPU of this VM had work | whole VM, summed over CPUs | not this process; with 2 vCPUs it can exceed wall time. A host that reports no steal to the guest gives 0 |
| `psi_io_some_ms`, `psi_cpu_some_ms` | time in which at least one task was stalled on IO / waiting for a CPU | whole system as the container sees it | needs `CONFIG_PSI` and PSI not turned off at boot. IO stall is counted at the block layer: reads served through FUSE or virtiofs wait elsewhere and may not count |

Per platform (to verify with the first lines that carry the counters; the readers return null wherever this is wrong):

| | `majflt` | `io_read_bytes` / `io_rchar` | `steal_ms` | PSI |
|---|---|---|---|---|
| Cloud Run gen1 (gVisor) | measured (0.4.3 smoke, 2026-11-11): 0 at load and at emit | measured: `read_bytes` 0, `rchar` real (about 0.7 MB at load, 9.4 MB at emit) | measured: 0 | measured: null |
| Cloud Run gen2 (microVM) | real Linux kernel: yes | file readable; `read_bytes` probably 0, since the image is not served from a block device the guest reads directly | present; real only if the host passes steal to the guest | depends on the guest kernel config; unknown |
| Lambda (Firecracker) | yes | file readable; `read_bytes` may be real for the image's block devices | present; same condition | probably missing: null |

Two things these counters cannot show:

- **A VM that is not run.** When the host stops running the VM's vCPUs, a task inside is "running" as far as the guest scheduler knows, so `schedstat` does not count the time as run-queue wait. If the host reports steal, it lands in `steal_ms`. A full pause (the guest clock stops, or the freezer holds the process) is in no counter. It stays the remainder: off CPU − run queue − IO stall − steal. The opt-in sampler of §2.2.3 measures it as a gap.
- **Network wait.** A blocking connect or read during boot is plain sleep. It is also in the remainder. The sampler of §2.2.3 counts it as `s_ms`.

Forked child: `majflt` and `/proc/self/io` restart at fork like the CPU clock, so their `*_at_load` values are null there. Steal and PSI are system-wide, but the span from the master's load to a worker's emit is not a boot, so their `*_at_load` values are null in a child too: one rule for every `*_at_load` field.

Skipped: `delayacct_blkio_ticks` (field 42 of `/proc/self/stat`), which would be the process's own block-IO wait. Delay accounting is off by default since kernel 5.14 (`delayacct` boot parameter or the `kernel.task_delayacct` sysctl), and when off the field reads 0, the same as "no IO wait". A value that cannot be told from "not measured" is left out.

Privacy: only numbers and fixed tokens (`v1`/`v2`/`gvisor`). No paths, no kernel version string, no hostnames, no env values. `phases_cpu_ms` is process CPU time, which says nothing about requests or users.

Not added: per-thread CPU, `/proc/pressure/memory` (the IO and CPU files were added in §2.2.2, read at load and at emit only), `delayacct_blkio_ticks` (§2.2.2), `memory.peak` (newer kernels only; candidate for later), other env flags. The one exception is `platform.lwa_async_init` (Lambda only, boolean, true only when the value is `"true"`; the value is never logged; Q3).

#### 2.2.3 Main-thread state sampler (opt-in, 2026-11-11)

§1.3 leaves one question the counters cannot answer: during the time off CPU, was the main thread blocked on IO, sleeping, or was the whole instance not running? `HAYAOKI_INSITU_SAMPLER=1` turns on a sampler that answers it with times. It is off by default and Linux only; elsewhere the `sampler` key of the line is null.

```json
"sampler": {"status": "ok", "until": "initialize_end", "interval_ms": 10, "wall_ms": 5210, "samples": 498,
            "r_ms": 1540, "d_ms": 3400, "s_ms": 120, "other_ms": 0,
            "gaps": 2, "gap_ms": 150, "gap_max_ms": 90, "truncated": false, "suspend_ms": 0,
            "sampler_cpu_ms": 28, "sampler_runq_wait_ms": 3, "sampler_majflt": 0, "fork_us": 800, "collect_us": 400}
```

**Method.** At load, right after the at-load counters are read, the process forks one child. Every 10 ms the child reads field 3 (state) of `/proc/<parent pid>/task/<parent pid>/stat`, the stat file of the parent's main thread (the thread-group leader, whose tid is the pid), and adds the time since its previous sample to the state it sees:

| Field | State | What it means for boot |
|---|---|---|
| `r_ms` | `R` | running or runnable. On-CPU time and run-queue wait together; the run-queue part is `proc.main_thread_runq_wait_ms` |
| `d_ms` | `D` | uninterruptible sleep: waiting for a page fault or a file read to be served (block device, FUSE and virtiofs requests included), or for a kernel lock |
| `s_ms` | `S` | interruptible sleep: a socket (DB, HTTP, DNS), `sleep`, a pipe, or a futex, which is also how the main thread waits for another Ruby thread or for the GVL |
| `other_ms` | anything else | stopped, traced, or a read that failed |

A step between two samples longer than 5 intervals (50 ms) is a **gap**: the child did not run. One interval of it goes to the state, the rest to `gap_ms`; `gaps` counts them and `gap_max_ms` is the longest. So `r_ms + d_ms + s_ms + other_ms + gap_ms = wall_ms`. A sample that is late by less than that is not lost: its whole step goes to the state seen.

The window ends at `initialize_end` (`"until": "initialize_end"`). After boot the main thread of a Puma process sleeps while server threads work, so later samples would add `S` time that is not boot. Without `initialize!` (not a Rails app, or a boot error) it ends when the line is built (`"until": "emit"`). The child is gone after that.

**Why not a Ruby thread.** A sampler thread in the same process needs the GVL to run. The main thread holds the GVL while it runs Ruby code, and it keeps holding it while it is blocked in the kernel in most of the places a cold boot waits: a major page fault on the Ruby binary, a shared library or bootsnap's cache, the `stat`/`open` calls of the `$LOAD_PATH` search, `dlopen` of an extension, a `read` done by C code that does not release the lock. Ruby's timer thread only asks the running thread to give up the GVL; a thread stuck in a page fault cannot answer. So a thread sampler would stop exactly when the main thread is in `D`, and that time would show up as a gap, the same as a paused instance. Pure Ruby has no thread that runs without the GVL. A Ractor has its own lock, but it prints an "experimental" warning, switches the VM into multi-Ractor mode for the rest of the process, and still stops with the main Ractor at every GC. A C extension could start a native thread, but the gem is pure Ruby (no `extensions` in the gemspec) and stays that way.

**Why fork and not spawn.** A forked child has its own GVL and is sampling within a millisecond. `Process.spawn` of a new `ruby` (or of `/bin/sh` with a loop) avoids copying the parent, but the new interpreter needs tens of ms of CPU before its first sample, it has to be found and started with a clean environment (`RUBYOPT`, shims), and a shell loop has no clock or sleep finer than what the image happens to ship. The cost of fork is the copy-on-write faults listed under Overhead.

**What a pause looks like.** The child is a process of the same instance, so whatever stops the instance stops the child too, and the child sees it as a gap on the same clock the line's marks use (`CLOCK_BOOTTIME`):

| What happens | Parent main thread | Child | In the line |
|---|---|---|---|
| Slow file IO or page faults | `D` | runs | `d_ms` |
| Network wait, `sleep`, waiting for a thread | `S` | runs | `s_ms` |
| cgroup CPU quota throttles the instance, or other work takes the CPUs | runnable (`R`), run-queue wait grows | also throttled: gaps, and its own run-queue wait grows | `gap_ms` with `sampler_runq_wait_ms` about as large |
| cgroup freezer holds the processes | frozen | frozen; a frozen task is not in the run queue | `gap_ms`, `sampler_runq_wait_ms` small |
| Host stops running the VM's vCPUs and the guest clock goes on (or jumps on resume) | not sampled | not running | `gap_ms`, `sampler_runq_wait_ms` small |
| Same, but the guest clock stops for the pause | – | – | nothing: the pause is not in the line's wall time either, so there is nothing to explain |
| Guest suspend and resume | – | – | `gap_ms`, and `suspend_ms` (`CLOCK_BOOTTIME` minus `CLOCK_MONOTONIC` over the window) |

Three numbers about the child itself qualify a gap. `sampler_runq_wait_ms` is the child's own run-queue wait (its `/proc/self/schedstat`): a gap it covers was a wait for a CPU, not a pause. `sampler_majflt` is the child's own major faults: a child that faulted was blocked on IO itself, and that time cannot be told from a pause, so a gap should be read as a pause only when this is 0. The parent does one sample before the fork, which also loads the code the child runs, to make this rare. `sampler_cpu_ms` is the child's CPU time.

**Lifecycle and safety.**

- Start. Only when the process has one thread at load (`"status": "threads"` otherwise): fork copies the calling thread alone, and a copy made while another thread held a lock can hang. `config/boot.rb` runs before any gem starts a thread. If the stat file cannot be opened or parsed, nothing is forked (`"status": "unsupported"`). A failed fork gives `"fork_failed"`. Loaded after `config/boot.rb` gives `"late_load"`. Nothing raises into the app.
- The child never writes to the app's output. Its stdin, stdout and stderr are reopened on `/dev/null`, it leaves through `exit!` (no `at_exit` handler of the app runs, nothing buffered is written twice), its process title is `hayaoki sampler`, GC is off (a GC would copy every page shared with the parent; the loop allocates little), and `TERM`/`INT`/`HUP`/`QUIT` have the system default action.
- Stop. The parent never writes to the child. It closes its end of a control pipe; the child sees end-of-file, takes a last sample, writes one line of integers to a result pipe and exits. The parent waits at most 100 ms for the line (`"status": "timeout"` and `SIGKILL` after that) and then reaps the child with a non-blocking wait, retried for at most about 20 ms. `$?` is not changed.
- If the parent exits, is killed or calls `exec`, the kernel closes the pipe and the child exits within one interval. The child also exits when the parent's thread is gone or a zombie. After an `exec` the new program does not know the child, so the child is left unreaped (a zombie) until the new program exits. The sampler starts only when hayaoki is loaded from `config/boot.rb` (`entry: boot_rb`); loaded later, other gems' fork hooks would run in the child, so `status` is `late_load`.
- If the parent forks (Puma cluster master, a daemonizing server), the sampler is ended before the fork so no worker inherits the pipes, and its result is dropped (`"status": "forked"`). A forked worker's line has `"sampler": null`, like the `*_at_load` fields: the samples belong to the process that booted the app. With `preload_app!` the window has normally ended at `initialize_end` before the first worker is forked.
- Whatever else happens, the child stops by itself after 120 s (`"truncated": true`), writes its line into the pipe and exits; the parent reads it later if it still asks. An instance frozen for an hour and thawed therefore has no sampler running afterwards.
- `at_exit` ends and reaps a child that is still there (rake, console, a process that wrote no line).

**Platform notes** (none of this is measured yet; the first lines with the field will tell):

| | Expected |
|---|---|
| Lambda (Firecracker) | fork works (Puma cluster runs there); real Linux `/proc`. 2 vCPUs during Init, so the child has a CPU. Rails apps end the sampler at `initialize_end`, before the environment can be frozen |
| Cloud Run gen2 | fork works; real Linux `/proc`; 5–6 CPUs visible at load in §1.3 |
| Cloud Run gen1 (gVisor) | fork works. gVisor writes its own stat file. File IO is done by the sandbox on behalf of the task, and the task probably shows as `R` meanwhile, so `d_ms` may stay near 0 whatever happened. `sampler_runq_wait_ms` is null (no schedstat) |
| A process that is pid 1 in its container | no difference: the parent reaps its own child |
| 1 vCPU | the child wakes 100 times a second for about 0.05 ms each; when the CPU is taken or throttled its samples are late and show as gaps with run-queue wait, which is the correct reading |

**Overhead.** Measured locally on macOS (arm64) with a file standing in for the stat file; Linux could not be run locally, so the Linux values are estimates until the first cloud lines, which carry `fork_us`, `collect_us`, `sampler_cpu_ms` and `samples` for this purpose.

| Cost | Where | Measured (macOS) | Expected on Linux |
|---|---|---|---|
| fork | parent, once at load | 0.6 ms | 0.5–2 ms for a process of 30–40 MB |
| copy-on-write faults | parent, while the child lives | not measured | each page the parent first writes after the fork is copied once: a few thousand pages of the at-load heap, about 3–20 ms in total, and up to that much extra memory (20–30 MB at most) until the child exits |
| one sample | child | 3 µs for read, parse and add; about 60 µs of CPU per sample with the wake-up | about 0.5 % of one CPU at 10 ms; 30 ms of CPU over a 5 s boot, on another CPU when there is one |
| ending the sampler | parent, once at `initialize_end` | 2.5–4 ms (mostly waiting for the child's exit in 1 ms steps) | 1–2 ms; at most about 120 ms when the child does not answer |

The fork and the end both fall inside the measured boot (`pre_bundler` and just after `initialize_end`), which is one reason the sampler is opt-in: it is a tool for a few diagnostic cold starts, not for every production boot.

**Not sampled.** `wchan` reads 0 for an unprivileged process on current kernels. `/proc/<pid>/syscall` needs ptrace access to the parent (denied to a child under the common Yama setting) and waits for the thread to leave the CPU. Other threads are not sampled: boot runs on the main thread (§2.2.1).

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
| `wait_dominated_boot` | share, quota, ready, sandbox; run-queue wait and the §2.2.2 counters for the text | G_n, G_ready, median `busy` ≤ 0.50. Four texts, §3.2 | `likely` |
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
  - When some lines are at or under `WAIT_BUSY` while the median passes 0.70, add: "{k} of {n} lines waited instead: on CPU 50% of the time or less." (issue #12; evidence `waited_lines`).
  - False positives: `cpu_ms` includes the first request and (without `cpu_at_load_ms`) the time before load; background threads can push share up; with an unknown quota a throttled CPU is not visible; lines with `worker: true` (forked child) have no `cpu_at_load_ms` and the old share is wrong there (the child's CPU clock restarts), so rules skip `worker: true` lines without it.
- **wait_dominated_boot**: "Boot likely spent most of its time waiting, not computing: on CPU {busy}% of the time (median of {n}). More CPU is unlikely to help. Likely causes: file IO (no bootsnap cache, many small files, lazily pulled image layers), network calls during boot (DB, secrets, HTTP in initializers), or CPU throttled before the first request." Cloud Run adds: "Try the other execution environment (gen1/gen2); file IO cost differs between them." With `sandbox: gvisor`: "gVisor system-call work is probably not counted as process CPU." This is the text when the run-queue wait is not known; §3.2 has the other three.
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

Note (2026-11-10, Q2 revised): with no nominal Lambda quota, the 0.2 Lambda Redmine 1024 row becomes `cpu_bound_boot` **possible** (busy 0.76, not clamped to 1.0) with the Init-CPU wording instead of "try 2048 MB". The 0.2 calibration test (`test_calibration_0_2_*`) expects that; the table above is kept as the record of the 0.2 reading.

With 0.3.1 lines (§1.1) and the revised Q2 (no nominal Lambda quota), the 0.4 calibration target is:

| Cell | busy (median) | Hints |
|---|---|---|
| CR gen1 minimal | 0.75 (quota 2 → 1.0) | `cpu_bound_boot` possible (already about one core; gVisor note; boost is on) |
| CR gen2 minimal | 0.29 from load | `wait_dominated_boot` likely; `prestarted_process` note |
| CR gen1 Redmine | 0.59 | `bootsnap_off` likely; no CPU hint |
| Lambda Redmine 1024 | 0.92 (quota unknown → 1.0) | `cpu_bound_boot` possible (more memory unlikely to help Init); `bootsnap_off` likely; `lambda_init_near_limit` likely (Init max 7.5 s) |
| Lambda Redmine 2048 | 0.94 | `cpu_bound_boot` possible; `bootsnap_off` likely |

With 0.4.1 / 0.4.2 lines (§1.2) and the split of §3.2:

| Cell | busy (median) | Run queue / off CPU | Hints |
|---|---|---|---|
| CR gen2 minimal (0.4.1) | 0.25 from load | 0.00 over the 4 lines that waited (1 ms of 4.6 s) | `wait_dominated_boot` likely, `wait_kind: not_cpu`; `prestarted_process` note |
| Lambda Redmine 1024 (0.4.2) | 0.91 | not read (the rule does not fire) | `cpu_bound_boot` possible; `bootsnap_off` likely |
| CR gen1 minimal, CR gen2 minimal (0.3.1) | as above | no fields | unchanged; `wait_dominated_boot` on gen2 has `wait_kind: unknown` and the 0.4.2 text |

### 3.2 `wait_dominated_boot`: waiting for a CPU or not (issue #12, 2026-11-11)

The rule fires as before (median `busy` ≤ 0.50). What changes is the text, chosen from the lines that waited.

Definitions, per line:

- A line **waited** when its own `busy` ≤ 0.50 and it has `cpu_at_load_ms` (the span must start at load, where the counters start).
- `off_cpu` = wall time from load to first response − process CPU over the same span.
- `runq` = `main_thread_runq_wait_ms − main_thread_runq_wait_at_load_ms`; `runq_share` = `runq / off_cpu`, clamped to 1.

Only lines that waited are read. When the median is at or under 0.50, at least half the lines waited, and those are the ones the hint is about; a fast line next to them has a small `off_cpu`, and its ratio would be noise (gen2: 2 fast lines of 6).

The kind needs at least 3 lines that waited and have both run-queue fields (`G_n` applied to the lines the split reads). Then, with the median `runq_share`:

| `wait_kind` | Condition | Text after the first sentence |
|---|---|---|
| `cpu` | ≥ 0.50 | "Most of the wait was for a CPU: the main thread waited in the run queue for {runq} of the {off_cpu} off CPU (median of {k} lines that waited). A CPU quota or other work on the same CPUs likely held boot back." then, when the quota is unknown or below 1, "More CPU (cpu=1 or more) or startup CPU boost may help."; with a quota of 1 or more, "A higher CPU limit or startup CPU boost may help." On Lambda the last sentence is "Init CPU does not follow the memory setting, so the remaining fix is less CPU work at boot: see `hayaoki boot-report`." |
| `not_cpu` | ≤ 0.20 | "It was not waiting for a CPU: the main thread waited ... , so throttling by a CPU quota is unlikely and more CPU is unlikely to help. Likely causes: file IO (...), network calls during boot (...), or the platform pausing the instance." |
| `mixed` | between | "Part of the wait was for a CPU: the main thread waited ... . More CPU may recover that part. Other likely causes: file IO (...), network calls during boot (...)." |
| `unknown` | fewer than 3 such lines (0.3.1 lines, gVisor, forked workers) | the 0.4.2 text, plus the counter sentence when counters exist |

Why these values:

- **0.50 for `cpu`**: the same "half or more" reading as `WAIT_BUSY`. The counter is the main thread only, so it undercounts if anything; half of the off-CPU time in the run queue is a clear sign. The text says "may help", not "will": a quota known to be below 1 vCPU already goes through `busy` and ends in `cpu_bound_boot`, so this branch is mostly reached with an unknown quota or with other work on the same CPUs.
- **0.20 for `not_cpu`**: the Lambda cell is CPU-bound and still has a median `runq_share` of 0.21 (0.09–0.29). Scheduling alone produces that much, so a share up to there says nothing about a CPU shortage. gen2 is at 0.00. Between 0.20 and 0.50 the text names both.
- In `not_cpu`, "CPU throttled before the first request" is dropped from the causes: a cgroup quota that throttles the process leaves it runnable, which `schedstat` counts. What cannot be excluded is the host not running the VM, hence "the platform pausing the instance" (§2.2.2).
- "The CPU quota is not visible; a quota below 1 vCPU would look like waiting" is only added for `unknown`. With a run-queue reading the quota does not have to be visible.
- "Try the other execution environment" is left out for `cpu`; the file IO difference between gen1 and gen2 is not the point there.

Supporting numbers. The §2.2.2 counters are medians of emit − load over the lines that waited, each over the lines that have it. They never decide the kind. The text lists the ones present after the causes: "Over the same span (median): {majflt} major page faults, {x} MB read from storage, system-wide IO stall (PSI) {y}, system-wide steal {z} summed over {N} CPUs." `io_read_bytes`, steal and PSI are listed only when above 0 (0 is what overlay and FUSE report for `io_read_bytes` whatever was read). The list is also added to the `unknown` text. On gVisor (`limits.sandbox` is `gvisor` in at least half of the lines) `majflt`, `io_read_bytes` and steal are dropped from the text and the evidence, since gVisor reports 0 for them whatever happened.

Naming a cause. The default is the neutral list of causes. Only in `not_cpu`, and only when the platform is Lambda or Cloud Run (an instance alone on its microVM or sandbox, so system-wide counters are about this boot), one of two sentences replaces it. On other platforms the numbers are shown and the neutral list stays:

- "IO stall time (PSI) covers most of the wait, so file IO is the likely main cause (...)." when the median of `psi_io_some / off_cpu` is ≥ 0.50.
- "Steal time covers most of the wait: the host likely did not run the instance's vCPUs for that time, which the app cannot change." when the IO sentence does not apply and the median of `steal / nproc / off_cpu` is ≥ 0.50. Steal is summed over CPUs, so it is divided by `limits.nproc`; with `nproc` missing there is no steal sentence.

PSI is the only counter here that is a time and is about IO, so it is the only one allowed to name file IO. Major faults and bytes read are sizes: 800 major faults can cost 10 ms or 4 s depending on where the pages come from, so they are shown but not read as a cause. The reverse is not concluded either: a low IO stall does not rule out file IO, because FUSE and virtiofs reads may not count in PSI. Both PSI and steal are system-wide; during boot the booting process is nearly the only work in the instance, which is why they are usable at all. Steal is summed over CPUs, which is why the sentence compares it per CPU, and it says "likely".

The remainder. When a line has run-queue wait, PSI IO stall and steal, `off_cpu − runq − psi_io_some − steal` (not below 0) is what no counter explains. Its median is in the evidence (`unaccounted_ms_p50`) and, for `not_cpu` and `mixed`, in the text: "{x} is in none of these counters: network wait, a paused instance, or file IO that PSI does not count (FUSE, virtiofs)." It is shown because it is the only place a paused instance can appear, and because a reader who sees "IO stall 400 ms" next to 4.8 s off CPU should also see that 4.4 s is unexplained. It is rough: the three counters can overlap (system-wide against one thread). Without PSI or steal it is null and not mentioned.

One id, not three. `wait_dominated_boot` keeps its id, level and trigger; the kind is the evidence field `wait_kind`. A separate id per kind would make the same set of lines change id when an optional field appears (a gVisor service has `unknown`, the same app on gen2 has `not_cpu`), and anything keyed on the id (dashboards, the calibration tests, `--format json` consumers) would see a hint disappear. The finding is the same in all four: boot waited. `cpu_bound_boot` evidence is unchanged.

Evidence added to `wait_dominated_boot` (all keys always present, null when not known): `wait_kind`, `wait_lines`, `non_cpu_ms_p50`, `runq_share_of_non_cpu_p50`, `majflt_p50`, `io_read_bytes_p50`, `steal_ms_p50`, `psi_io_some_ms_p50`, `psi_cpu_some_ms_p50`, `unaccounted_ms_p50`.

False readings to keep in mind:

- The run-queue wait is the main thread's; `off_cpu` uses all-thread CPU and ends at the first response, which a server thread handles. In a boot the difference is small (gen2: `phases_cpu_ms.load_to_first_response` and the process CPU agree within 6 ms).
- Whether cgroup throttling is counted as run-queue wait on gen2 has not been measured on a cell with a quota below 1 vCPU (§2.2.1). The `not_cpu` text says "unlikely", not "ruled out".
- The PSI and steal sentences have no cloud measurement behind them yet. The 0.4.1 / 0.4.2 lines predate the counters.

---

#### Sampler cause (0.4.5)

Per line that waited with `sampler.status == "ok"`: off = `wall_ms - r_ms`, so the window is load to `initialize_end`; lines with off <= 0 are skipped. Shares are `d_ms / off`, `s_ms / off` and `(gap_ms + suspend_ms) / off`. With 3 or more such lines the medians are in the evidence (`sampler_lines`, `sampler_d_share_p50`, `sampler_s_share_p50`, `sampler_pause_share_p50`; null when not known). For `not_cpu`, `mixed` and `unknown`, the first share at 0.50 or more names the cause, in the order D (file IO or page faults), pause (the platform paused the instance; more CPU is unlikely to help), S (network calls or sleeps). It replaces the generic causes list and wins over the PSI sentence. Below 0.50 the text stays and gets "Sampler (median): D x%, S y%, paused z% of the time off CPU." `wait_kind`, ids and levels do not change.

0.4.4 measurements: Cloud Run gen2 slow lines have R 1.6-2.0 s, D 2.4-5.9 s, S up to 7 ms, no gaps and no suspend; the fast line has R 1.33 s and D 0.27 s. On Lambda R is about the CPU time, D is 155-640 ms and S is about 0, so `cpu_bound_boot` stays.

## 4. What cannot be seen from inside

| Setting | Visible? | How the wording handles it |
|---|---|---|
| Cloud Run startup CPU boost | Only indirectly, if `cpu.max` at load shows more than the configured CPU (and we do not know the configured CPU) | "If startup CPU boost is not on, turn it on" |
| Cloud Run CPU allocation (request-based / always on) | No | wait / prestarted hints mention "throttled before the request" as one possible cause; `wait_dominated_boot` drops it when the run-queue wait shows the process was not waiting for a CPU (§3.2) |
| The host pausing or not running the instance | Only as steal, if the host reports it; a full pause is in no counter | "the platform pausing the instance" as a possible cause; the remainder of §3.2 |
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
- Sampler (`test/insitu/sampler_test.rb`): the aggregation with a given list of (time, state) samples, the state parser on stat lines given as strings, the loop with an injected clock, state source and wait, and the wire format. The child process is tested with a real fork against a file the test writes in place of the stat file (start, result, reap, parent exit, the 120 s limit shortened, a child that does not answer, an app fork). No test reads the real `/proc`; the one check of the real path is the integration test, which expects `status: ok` on Linux and null elsewhere.
- Calibration test: synthetic sets that copy the per-cell medians of §1 (numbers only) must produce exactly the hints in §3.1. If a threshold changes, this table and the test change together.
- Formatters: text and JSON for one set with three hints, one with none, one under `G_n`.
- No real data in fixtures: no IDs, URLs, account numbers, emails or log stream names. A test greps the fixture dir for patterns like long hex or 12-digit numbers.

---

## 7. Scope

0.3.0: §2.2 fields, reader `INIT_REPORT` status, the 8 rules, text/JSON output, README section, re-measurement of the CR cells and Lambda Redmine with the new fields (the user runs it).

Deferred: hints that compare two groups (for example "2048 MB was 1.2 s faster than 1024 MB" from one `--group-by memory_mb` run; candidate for 0.3.x), memory PSI, `memory.peak`, Cloud Run / Lambda API lookups of the real settings, a Lambda Telemetry API extension.

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
- Q2 (replaced 2026-11-10): Lambda uses the nominal `memory_mb / 1769` quota when cgroup gives nothing; wording says "estimate".
- Q2 revised (2026-11-10, after §1.1): no nominal quota on Lambda. The quota is unknown there; `cpu_bound_boot` on Lambda is at most `possible`, and its text says that Init reportedly gets CPU independent of memory, so more memory is unlikely to shorten Init; the fix is less CPU work at boot. `lambda_init_near_limit` drops "more memory (more CPU during Init)" from its options.
- `cpu_bound_boot` wording when quota ≥ 1: do not claim that more vCPU never helps. Say the process already uses about one core; on gVisor (gen1) sandbox work shares the same quota, so more vCPU can still help there.
- `G_ready` for the CPU rules (0.4 implementation): the gate runs over the set the rule reads, not only `ok_p`. A rejected start (gen2) has the load mark as origin, so its `to_ready` is already from load; a 0.2.0 bad `/proc` start is corrected by subtracting `pre_load`. Without this, gen2 cells (all starts rejected) could never get `wait_dominated_boot`. §3 only names `ok_p`; this is the stricter reading for plausible lines and the only workable one for the rest.
- Thresholds after step 8 (0.4, local 0.3.1 data): unchanged. Measured medians with the report's nearest-rank median: gen1 minimal 0.72 (§1.1 says 0.75: the mean of the two middle lines; two of six lines waited at about 0.4), gen2 0.29, gen1 Redmine 0.59, Lambda Redmine 0.90 / 0.93. Every cell lands where the second §3.1 table says. gen1 minimal stays the borderline case (0.72 against 0.70).
- Run-queue wait (2026-11-10, issue #12): record `/proc/self/schedstat` field 2 for the main thread at load and at emit (`proc.main_thread_runq_wait_at_load_ms`, `proc.main_thread_runq_wait_ms`), not a per-thread sum and no extra read at other marks; reasons in §2.2.1. The rules only show its median as evidence and add the "k of n lines waited" note; splitting `wait_dominated_boot` into CPU-wait and IO-wait text waits for the cloud check.
- Split of `wait_dominated_boot` (2026-11-11, issue #12, after §1.2): the hint keeps its id and gets four texts by `wait_kind` (`cpu` at a run-queue share of the off-CPU time ≥ 0.50, `not_cpu` at ≤ 0.20, `mixed` between, `unknown` without the fields), read from the lines that waited. New line fields `majflt`, `io_read_bytes`, `io_rchar`, `steal_ms`, `psi_io_some_ms`, `psi_cpu_some_ms` with `*_at_load` twins are supporting numbers only; file IO is named as the main cause only when PSI IO stall is at least half of the off-CPU time. `delayacct_blkio_ticks` is not recorded. Details in §2.2.2 and §3.2. Open: whether gen2 and Lambda expose PSI and steal, and a cell with a quota below 1 vCPU.
- Main-thread state sampler (2026-11-11, after §1.3): opt-in by `HAYAOKI_INSITU_SAMPLER=1`, a forked child that samples the main thread's state every 10 ms from load to `initialize_end` and reports `r_ms` / `d_ms` / `s_ms` and its own gaps in a `sampler` object. A child process because a Ruby thread cannot run while the main thread is blocked with the GVL. The report does not read the object yet; rules and thresholds are decided after the first real lines. Details in §2.2.3. Open: all Linux numbers (overhead, gVisor states, whether a gen2 slow boot is `D` or a gap).
- Q3: yes, record a boolean for `AWS_LWA_ASYNC_INIT` presence (not its value).
- Q4: flag only (`mixed: true`); users split with `--group-by`.
- Q5: decide after the 0.4 implementation.
- Q6: hints on by default in text output; `--no-hints` turns them off.
- Q7: 7 s.

---

## Sources

- [L9] Classmethod, "LambdaのINITフェーズではメモリ128MでもCPUパワーをフルに使える?!boost host CPUの動きを確認してみた": https://dev.classmethod.jp/articles/lambda-boost-host-cpu-in-init-phase/ (measured: CPU in the first 10 s of Init is independent of memory)
- [L10] AWS Lambda Web Adapter, Async Initialization ("up to 10 seconds ... with burst CPU"): https://aws.github.io/aws-lambda-web-adapter/configuration/async-init.html

- phase2.md Sources [L1]–[L7], [C1]–[C3] (Init 10 s limit and INIT_REPORT; LWA async init; Cloud Run startup CPU boost and CPU limits).
- [L8] Lambda memory and CPU (CPU proportional to memory; 1 vCPU at 1,769 MB): https://docs.aws.amazon.com/lambda/latest/dg/configuration-memory.html — to verify that the figure is current.
- To verify: whether Cloud Run gen1 (gVisor) and gen2 expose `/sys/fs/cgroup/cpu.max` and `memory.max` to the container; the gVisor `/proc/version` string; answered in §1.1: gen1 and gen2 expose cgroup v1 files, the gVisor check works, Lambda Init CPU does not follow the memory ratio.
