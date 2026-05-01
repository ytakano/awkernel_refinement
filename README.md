# awkernel_refinement

This repository keeps refinement-facing tooling split into three layers:

- `scheduling_theory/`: common Rocq theory and extracted Haskell checkers
- `scripts/` and top-level `Makefile`: adapter scripts that connect emitted Awkernel traces to the extracted checkers
- `awkernel/`: concrete runtime build, QEMU/KVM execution, and trace emission

## Prerequisites

- Rust toolchain required by `awkernel`
- `qemu-system-x86_64`
- GHC for native checker binaries
- OVMF files under `awkernel/target/ovmf/x64`

## Common Commands

Build the native workload checker:

```sh
make target/adapter/haskell/workload_acceptance
```

Run the adapter contract tests:

```sh
make check-workload-accept-contract
```

Run a workload acceptance check through QEMU:

```sh
make check-workload-accept-qemu-2cpu WORKLOAD_SCENARIO=single_async
```

Available workload scenarios:

```text
single_async nested_spawn multi_async sleep_wakeup generic_random
```

Run the generic random workload seed loop:

```sh
make check-generic-random-workload-seeds GENERIC_RANDOM_RUNS=100
```

Handoff reasoning is currently exposed as generic common-layer contracts and
downstream adapter obligations. It is not a separate top-level acceptance lane;
current validation is organized around baseline trace compatibility and
workload acceptance.

Workload acceptance consumes emitted `sched_trace` and `task_trace` blocks as
adapter evidence. Rows may carry a leading numeric `event_id`; the `event_id`
is an ordering key for runtime capture, blocked-interval reconstruction, and
diagnostics, not a common `OpState` field or `OpEvent` payload.

The `_trace_vm` Cargo features used by the Awkernel build are userland and
application selectors. They select the runtime-emitted workload application and
enable the concrete trace hooks needed by the offline checkers; they are not a
common-layer interface and do not add proof obligations to the common theory.

Blocked-work observations follow the same layering. The common layer states
only that blocked work is released but temporarily ineligible. Concrete
`Block`/`Unblock` evidence, such as sleep or TCP/UDP I/O hooks, belongs to the
adapter/runtime projection and is interpreted by the Awkernel workload checker
as adapter-local blockedness evidence, not as a common-layer cause.

Dispatch-model selection is also layered. `DispatchModel` is a common selector
type with strict and spurious modes, but spurious dispatch is not a common
`OpEvent` constructor and not a separate `op_step`. The Awkernel workload
adapter selects the spurious model only to accept raw blocked dispatch rows as
runtime-local evidence. Those rows contribute no abstract progress, completion,
service accounting, or scheduler candidate relation.

## Compatibility

The concrete runtime repository still supports compatibility entrypoints such as:

```sh
make -C awkernel check-workload-accept-contract
make -C awkernel check-workload-accept-qemu-2cpu WORKLOAD_SCENARIO=single_async
```

These delegate to the top-level adapter targets. New cross-repository checks should prefer the top-level `Makefile`.
