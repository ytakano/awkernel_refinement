# Awkernel KVM Trace VM

This note records the concrete libvirt/KVM VM used to capture a 2 CPU
`periodic_trace_vm` trace from Awkernel.

## Purpose

The VM is a concrete runtime harness for collecting serial trace evidence from
Awkernel. It is not a common-layer proof interface. The common scheduling
theory continues to consume the projected `sched_trace` and `task_trace`
artifacts; libvirt, QEMU machine type, host CPU ids, Linux FIFO priorities, and
host paths remain concrete runtime details.

## Configured VM

The configured persistent libvirt domain is:

```sh
virsh -c qemu:///system dominfo awkernel-periodic-2cpu
```

Current intended shape:

- Domain: `awkernel-periodic-2cpu`
- Host Awkernel image: `/home/ytakano/program/awkernel_refinement/awkernel/x86_64_uefi.img`
- Machine: `pc-i440fx-jammy`
- Disk: `hda` on IDE
- Firmware: system OVMF, non-secure boot
- Serial log source: `/var/lib/libvirt/images/awkernel-periodic-2cpu.log`
- Downloaded checker input: `/tmp/awkernel_kvm_2cpu_periodic.log`

The `pc-i440fx-jammy` plus IDE disk shape is intentional. The earlier
`q35`/SATA attempt booted only into UEFI screen control output and did not reach
Awkernel. The existing `vm1` domain showed that Awkernel's UEFI image boots
under `pc-i440fx-jammy` with an IDE `hda` disk.

## CPU, Affinity, and Scheduling

The VM uses the following 2 CPU host placement policy:

- vCPU 0: host CPU 4, FIFO 80
- vCPU 1: host CPU 6, FIFO 80
- QEMU emulator: host CPU 8, FIFO 50
- QEMU IOThread 1: host CPU 10, FIFO 60

Verify the live settings while the VM is running:

```sh
virsh -c qemu:///system vcpuinfo awkernel-periodic-2cpu
virsh -c qemu:///system emulatorpin awkernel-periodic-2cpu
virsh -c qemu:///system iothreadinfo awkernel-periodic-2cpu
```

## Refresh the Awkernel Image

Build the periodic trace VM image before running the domain:

```sh
make -C /awkernel_refinement/awkernel build-workload-trace-x86_64 WORKLOAD_SCENARIO=periodic
```

The libvirt domain reads the host-visible image path directly:

```text
/home/ytakano/program/awkernel_refinement/awkernel/x86_64_uefi.img
```

If the workspace path changes, update the domain XML disk source before running
the VM.

## Capture a Trace

Start the VM:

```sh
virsh -c qemu:///system start awkernel-periodic-2cpu
```

Wait for the VM to shut down. The periodic trace workload normally completes
and powers off by itself. Check state:

```sh
virsh -c qemu:///system dominfo awkernel-periodic-2cpu
```

Download the serial log to the path expected by the checker workflow:

```sh
virsh -c qemu:///system vol-download \
  --pool default \
  awkernel-periodic-2cpu.log \
  /tmp/awkernel_kvm_2cpu_periodic.log
```

The downloaded log should contain:

- `BEGIN_SCHED_TRACE`
- `END_SCHED_TRACE`
- `BEGIN_TASK_TRACE`
- `END_TASK_TRACE`
- `PeriodicJobComplete` rows for loop indices `0` through `9`

## Validate the Trace

Build the Haskell workload acceptance checker:

```sh
make -C /awkernel_refinement target/adapter/haskell/workload_acceptance
```

Run the acceptance check:

```sh
python3 /awkernel_refinement/scripts/check_workload_acceptance.py \
  --backend kvm-workload \
  --scenario periodic \
  --log /tmp/awkernel_kvm_2cpu_periodic.log \
  --checker-bin /awkernel_refinement/target/adapter/haskell/workload_acceptance
```

Expected result:

```text
kvm-workload-periodic: accepted
```

## Troubleshooting Notes

- If the log contains only UEFI escape/control output, confirm that the domain
  uses `pc-i440fx-jammy` and IDE `hda`, not `q35` and SATA.
- If `virsh start --console` fails with a TTY error, use the configured
  file-backed serial log and `vol-download` instead.
- If direct `qemu-system-x86_64 -enable-kvm` fails from the development
  environment, use libvirt. This environment may not expose `/dev/kvm` directly.
- Do not disable AppArmor confinement just to pass custom QEMU command-line
  pflash arguments. The working setup uses libvirt-supported firmware and disk
  configuration instead.

## Refinement Boundary

This VM setup belongs to the concrete runtime layer. It provides observable
serial trace artifacts that the adapter/checker consumes. The common layer does
not depend on:

- libvirt or `virsh`
- QEMU machine type or disk bus
- OVMF paths
- host CPU ids
- Linux FIFO priorities
- serial log file locations

Downstream adapter validation is responsible for checking that the captured
`sched_trace` and `task_trace` are complete, ordered, parseable, and accepted by
the workload checker.
