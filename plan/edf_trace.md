# EDF trace adapter acceptance roadmap

## Goal

Awkernel の `GlobalEDF` policy を持つ workload trace と、
`GlobalEDF` / `PrioritizedFIFO` が混在する workload trace を adapter で受理可能にする。
DAG 由来の GEDF semantics と複数 CPU scheduling は、この minimal roadmap では扱わない。

v1 は runtime 実装に忠実な受理を目標にする。つまり adapter は
`Spawn GlobalEDF <relative_deadline>` だけから deadline を合成しない。
Awkernel runtime が GEDF wake 時に計算した `absolute_deadline` を trace に出し、
adapter はその観測値を使って EDF 順序を検査する。混在 policy の場合は、
Awkernel の scheduler priority order のうち minimal path で扱う prefix、
`GlobalEDF > PrioritizedFIFO` を adapter-local rule として検査する。

## Layer boundary

### Common layer

Common layer は変更しない。

Common layer が保持するのは、抽象 scheduler relation、candidate source、
valid schedule、adapter contract である。EDF trace 固有の policy metadata、
`wake_time`、`absolute_deadline`、unsupported-policy diagnostic は
`OpState`, `OpEvent`, `OSProjection`, `OSLabeledProjection` に入れない。
Common が見る runnable は抽象 runnable view だけである。`sched_trace.runnable`
は adapter-facing evidence であり、Awkernel adapter が scheduler queue-visible
state から導く。`TaskInfo.state` と queue layout は common interface ではない。

### Adapter layer

Adapter layer は Awkernel が出した trace artifact を読み、common layer に渡せる
proof-facing witness を構成する。

EDF および EDF/FIFO 混在受理で adapter が負う責務は以下である。

- `GlobalEDF` task policy metadata を検証する。
- `GlobalEDF` / `PrioritizedFIFO` 混在を supported policy set として扱う。
- `PrioritizedRR`, `Panicked`, unknown policy を v1 では reject する。
- non-DAG EDF task の release/deadline metadata を復元する。
- `sched_trace.runnable` を scheduler queue-visible state 由来の abstract runnable view として扱う。
- blocked task に対する adapter-local spurious row filtering を既存 FIFO path と同じ境界で適用する。
- `GlobalEDF` candidate が存在する row では、候補集合と選択結果が EDF scheduler relation を満たすことを検査する。
- `GlobalEDF` candidate が存在しない row では、既存 FIFO checker と同じ規則で `PrioritizedFIFO` selection を検査する。
- 受理済み trace を common scheduler-relation adapter contract へ package する。

`DispatchModel` は common type だが、ここで使う Spurious selection は
Awkernel adapter の受理方針であって、common `OpEvent` や `op_step` を増やすものではない。
blocked/spurious dispatch row は runtime-local evidence として parser/checker 境界で
保持できるが、EDF/FIFO scheduler relation、candidate relation、service、
completion、progress の witness には寄与しない。

### Concrete runtime layer

Concrete runtime layer は adapter が必要とする observable を出す。
Runtime は queue-visible runnable state を trace に出してよいが、`TaskInfo.state`
や concrete queue layout そのものを common-facing observable にはしない。

`TaskTraceEvent::Spawn` の `GlobalEDF <relative_deadline>` は task の policy 設定を示す
metadata として維持する。ただし runtime GEDF は release ごとに absolute deadline を計算するため、
Spawn metadata だけでは EDF の比較キーとして不十分である。

`GEDFScheduler::wake_task` で non-DAG task の `wake_time` と `absolute_deadline` を計算した直後に、
adapter-local な `RunnableDeadline` event を task trace に追加する。

`PrioritizedFIFO` task は既存の Spawn policy metadata と FIFO candidate ordering を使う。
FIFO task に deadline metadata は要求しない。

## Interface delta

### Task trace

既存の task trace row:

```text
event_id kind subject related wait_class unblock_kind policy policy_param
```

Spawn row は現状のまま維持する。

```text
0 Spawn 1 - - - GlobalEDF 100
```

EDF 用に release/deadline を表す adapter-local `RunnableDeadline` event を追加する。
この event は release projection と deadline evidence を同時に表す。

必要な payload は以下である。

- `task_id`
- `wake_time`
- `absolute_deadline`
- 任意の consistency check 用 `relative_deadline`

8-column trace format を維持するだけでは `wake_time` と `absolute_deadline` の両方を
自然に表現しにくい。実装では EDF metadata 用の追加 column を許すか、
policy-specific metadata field を parser 側で明確に定義する。

### Mixed-policy selection rule

Adapter の v1 supported policy set は `GlobalEDF` と `PrioritizedFIFO` である。
`PrioritizedRR`, `Panicked`, unknown policy は unsupported policy diagnostic として reject する。

各 scheduler-facing row では、blocked/spurious filtering 後の visible candidates を
policy ごとに分類する。

- `GlobalEDF` candidate が存在する場合、選択 task は `GlobalEDF` candidate の中で
  `absolute_deadline` が最小の task でなければならない。
- `absolute_deadline` が同値の場合は `wake_time` が小さい task を優先する。
- `absolute_deadline` と `wake_time` が完全に同値の場合は同順位として扱い、
  その同順位集合内の選択を許容する。
- `GlobalEDF` candidate が存在しない場合、選択 task は既存 FIFO checker と同じ
  `PrioritizedFIFO` ordering を満たさなければならない。

この規則は Awkernel runtime の scheduler priority order
`GEDF > PrioritizedFIFO > PrioritizedRR > Panicked` のうち、
minimal adapter で扱う `GEDF > PrioritizedFIFO` prefix を trace checker に射影する。
Common layer の policy interface ではない。

### Rocq adapter types

`Operational/Awkernel/Minimal` に adapter-local な EDF metadata を追加する。

- `AwkernelTaskPolicy` の `AtpGlobalEDF relative_deadline` は supported EDF policy として扱う。
- `AtpPrioritizedFIFO priority` は mixed-policy path の supported FIFO policy として扱う。
- `RunnableDeadline` event または metadata record を task trace entry に追加する。
- periodic task の同一 runtime task 再利用は adapter-local に
  `RunnableDeadline(..., loop_index)` と `PeriodicJobComplete(task, loop_index)`
  で logical job 列として識別する。Common layer の `JobId` は変更しない。
- task summary に task policy table と EDF deadline table を保持する。
- task summary に periodic job completion table を保持し、同じ
  `(task, loop_index)` の二重 complete を reject する。
- Common layer の job/interface は変更せず、adapter が `Job.job_abs_deadline` を
  trace 由来の `absolute_deadline` へ復元する。

## Implementation steps

1. Runtime trace emission

   `awkernel_async_lib/src/scheduler/gedf.rs` の `GEDFScheduler::wake_task` で、
   non-DAG task の `wake_time` と `absolute_deadline` を計算した直後に
   `RunnableDeadline` trace を記録する。DAG task と複数 CPU scheduling は
   minimal path の対象にしない。

2. Task trace parser

   Haskell parser が `RunnableDeadline` metadata row を読めるようにする。
   periodic row では既存10列 format の末尾に `loop_index` を追加した11列
   `RunnableDeadline` と、9列 `PeriodicJobComplete` を読む。
   malformed deadline metadata は task-trace parse failure として task trace index を返す。

3. Rocq workload acceptance

   `WorkloadAcceptance.v` に supported mixed-policy predicate と first failing index を追加する。

   - `task_trace_all_global_edf_policyb`
   - `first_non_global_edf_task_policy_index`
   - `task_trace_all_edf_fifo_policyb`
   - `first_non_edf_fifo_task_policy_index`
   - EDF deadline metadata well-formedness check
   - task ごとの latest release/deadline lookup
   - periodic `loop_index` metadata consistency check
   - periodic job completion uniqueness check

4. Rocq scheduler-facing checker

   `WorkloadSchedulerFacing.v` に `Multicore.Global.GlobalEDF` を import し、
   FIFO checker と並ぶ EDF/FIFO mixed checker を追加する。

   - EDF 用 reconstructed jobs
   - `job_abs_deadline` は EDF deadline metadata の `absolute_deadline`
   - `GlobalEDF` candidate が存在する場合は `choose_top_m global_edf_top_m_spec ... edf_candidates`
   - `GlobalEDF` candidate が存在しない場合は既存 FIFO row checker
   - `sched_trace_edf_fifo_scheduler_relation_checkb`
   - `first_non_edf_fifo_scheduler_relation_sched_trace_index`
   - `awk_workload_accepts_edf_fifo_scheduler_relation_sched_trace`
   - sound/complete lemmas

5. Checker frontend dispatch

   `scripts/haskell/WorkloadAcceptanceMain.hs` の acceptance flow を以下に分岐する。

   - all `PrioritizedFIFO`: existing FIFO checker
   - all `GlobalEDF`: new EDF/FIFO checker with only EDF candidates
   - mixed `GlobalEDF` / `PrioritizedFIFO`: new EDF/FIFO checker
   - `PrioritizedRR`, `Panicked`, unknown policy: adapter-local policy rejection

   成功 message は `GlobalFIFO` 固定文言から、選択された policy を含む文言へ更新する。

6. Extraction

   `WorkloadAcceptanceExtraction.v` に EDF 用 checker と diagnostic helper を追加し、
   extracted Haskell を再生成する。

7. Documentation

   `awkernel_refinemnet_doc` と `scheduling_theory/design` に、EDF trace metadata は
   adapter-local evidence であり common interface ではないことを書く。
   実装済みの minimal boundary として、non-DAG GEDF release の
   `RunnableDeadline` metadata、periodic logical job の `loop_index` と
   `PeriodicJobComplete` metadata、`GlobalEDF` / `PrioritizedFIFO` の supported
   policy set、`PrioritizedRR` / `Panicked` / unknown policy の reject、
   `GlobalEDF` visible candidate 優先と FIFO fallback、DAG GEDF と multi-CPU EDF の
   scope exclusion、unsupported-policy / edf-deadline-metadata / edf-fifo
   diagnostics を記録する。

## Tests

### Rust tests

- `GlobalEDF` Spawn が現行 format で policy metadata を出す。
- non-DAG GEDF wake が `wake_time` と `absolute_deadline` を含む `RunnableDeadline` trace を出す。
- `absolute_deadline = wake_time + relative_deadline` が trace 上で確認できる。
- periodic task helper が `loop_index` 付き `RunnableDeadline` と
  `PeriodicJobComplete` を出す。

### Rocq and extraction tests

- `make theories/Operational/Awkernel/Minimal/WorkloadAcceptance.vo`
- `make theories/Operational/Awkernel/Minimal/WorkloadSchedulerFacing.vo`
- `make extract-workload-accept-hs`
- extracted Haskell の diff を確認し、trailing whitespace を残さない。

### Contract tests

- single-task `GlobalEDF` trace is accepted.
- two-task `GlobalEDF` trace chooses the earlier `absolute_deadline`.
- wrong EDF choose order is rejected with `sched_trace_index`.
- EDF/FIFO mixed trace is accepted when an EDF candidate is chosen over FIFO candidates.
- EDF/FIFO mixed trace is rejected when a FIFO candidate is chosen while an EDF candidate is visible.
- FIFO fallback is accepted when no EDF candidate is visible.
- `PrioritizedRR`, `Panicked`, unknown policy remain rejected.
- malformed EDF deadline metadata reports `task_trace_index`.
- periodic `RunnableDeadline` with a loop index is accepted.
- duplicate `PeriodicJobComplete(task, loop_index)` is rejected.
- blocked task の raw `Choose` は既存方針どおり spurious adapter row として扱い、
  blocked task の `Dispatch` は abstract scheduler service へ入れない。
- Spurious dispatch model で受理された blocked `Dispatch` は common `EvDispatch`
  ではなく、progress/completion/service/candidate relation を作らない。

### End-to-end commands

```sh
cargo test -p awkernel_async_lib baseline_trace --features std,baseline_trace
make check-workload-accept-contract
make target/adapter/haskell/workload_acceptance
make test
```

この repository では root `make test` が存在しない可能性がある。
その場合は失敗理由を記録し、上記の subsystem test 結果を明示する。

## Open risks

- EDF は release ごとに比較キーが変わるため、Spawn の relative deadline だけでは
  runtime-faithful な受理にならない。
- Runtime GEDF の tie-break は `absolute_deadline` 同値時に `wake_time` を使う。
  Adapter checker でも同じ tie-break を明文化する必要がある。
- DAG GEDF と複数 CPU scheduling は minimal roadmap の対象外である。
  それらを追加する場合は、別 roadmap で deadline 計算規則と worker capacity を扱う。
- 既存 FIFO checker と EDF checker の diagnostic を混ぜると原因が曖昧になる。
  frontend は policy dispatch 後に policy-specific diagnostic を返す。
