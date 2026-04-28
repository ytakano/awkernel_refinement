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

## Compatibility

The concrete runtime repository still supports compatibility entrypoints such as:

```sh
make -C awkernel check-workload-accept-contract
make -C awkernel check-workload-accept-qemu-2cpu WORKLOAD_SCENARIO=single_async
```

These delegate to the top-level adapter targets. New cross-repository checks should prefer the top-level `Makefile`.
