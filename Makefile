AWKERNEL_DIR ?= awkernel
SCHEDULING_THEORY_DIR ?= scheduling_theory

GHC ?= ghc
GHCFLAGS ?= -O2
ACCEPT_CHECKER_DIR ?= $(SCHEDULING_THEORY_DIR)/extracted/haskell
ADAPTER_TARGET_DIR ?= target/adapter
HASKELL_ACCEPT_TARGET_DIR ?= $(ADAPTER_TARGET_DIR)/haskell
WORKLOAD_ACCEPT_BIN ?= $(HASKELL_ACCEPT_TARGET_DIR)/workload_acceptance
WORKLOAD_ACCEPT_RUNNER ?= scripts/haskell/WorkloadAcceptanceMain.hs

BASELINE_TRACE_EXPECTED ?= $(AWKERNEL_DIR)/fixtures/baseline_trace/faithful_2cpu.txt
BASELINE_TRACE_QEMU_LOG ?= /tmp/awkernel_qemu_2cpu_baseline.log
BASELINE_TRACE_KVM_LOG ?= /tmp/awkernel_kvm_2cpu_baseline.log

WORKLOAD_SCENARIO ?= single_async
WORKLOAD_TRACE_QEMU_LOG ?= /tmp/awkernel_qemu_2cpu_$(WORKLOAD_SCENARIO).log
WORKLOAD_TRACE_KVM_LOG ?= /tmp/awkernel_kvm_2cpu_$(WORKLOAD_SCENARIO).log
WORKLOAD_TRACE_TIMEOUT ?= 120s
GENERIC_TRACE_SEED ?=
GENERIC_RANDOM_RUNS ?= 1
WORKLOAD_SCENARIOS ?= single_async nested_spawn multi_async sleep_wakeup generic_random periodic

capture-baseline-log-qemu-2cpu:
	$(MAKE) -C $(AWKERNEL_DIR) $@ BASELINE_TRACE_QEMU_LOG=$(BASELINE_TRACE_QEMU_LOG)

capture-baseline-log-kvm-2cpu:
	$(MAKE) -C $(AWKERNEL_DIR) $@ BASELINE_TRACE_KVM_LOG=$(BASELINE_TRACE_KVM_LOG)

capture-workload-log-qemu-2cpu:
	$(MAKE) -C $(AWKERNEL_DIR) $@ \
		WORKLOAD_SCENARIO=$(WORKLOAD_SCENARIO) \
		WORKLOAD_TRACE_QEMU_LOG=$(WORKLOAD_TRACE_QEMU_LOG) \
		WORKLOAD_TRACE_TIMEOUT=$(WORKLOAD_TRACE_TIMEOUT) \
		GENERIC_TRACE_SEED=$(GENERIC_TRACE_SEED)

capture-workload-log-kvm-2cpu:
	$(MAKE) -C $(AWKERNEL_DIR) $@ \
		WORKLOAD_SCENARIO=$(WORKLOAD_SCENARIO) \
		WORKLOAD_TRACE_KVM_LOG=$(WORKLOAD_TRACE_KVM_LOG) \
		WORKLOAD_TRACE_TIMEOUT=$(WORKLOAD_TRACE_TIMEOUT) \
		GENERIC_TRACE_SEED=$(GENERIC_TRACE_SEED)

check-baseline-trace-qemu-2cpu: capture-baseline-log-qemu-2cpu
	python3 scripts/check_baseline_trace.py \
		--backend qemu \
		--expected $(BASELINE_TRACE_EXPECTED) \
		--log $(BASELINE_TRACE_QEMU_LOG)

check-baseline-trace-kvm-2cpu: capture-baseline-log-kvm-2cpu
	python3 scripts/check_baseline_trace.py \
		--backend kvm \
		--expected $(BASELINE_TRACE_EXPECTED) \
		--log $(BASELINE_TRACE_KVM_LOG)

check-baseline-trace-2cpu: check-baseline-trace-qemu-2cpu check-baseline-trace-kvm-2cpu

refresh-baseline-trace-fixture-qemu-2cpu: capture-baseline-log-qemu-2cpu
	python3 scripts/extract_trace_artifact.py \
		--mode baseline \
		--log $(BASELINE_TRACE_QEMU_LOG) \
		--output $(BASELINE_TRACE_EXPECTED)

refresh-trace-fixtures-qemu-2cpu: refresh-baseline-trace-fixture-qemu-2cpu

check-workload-accept-qemu-2cpu: capture-workload-log-qemu-2cpu $(WORKLOAD_ACCEPT_BIN)
	python3 scripts/check_workload_acceptance.py \
		--backend qemu-workload \
		--scenario $(WORKLOAD_SCENARIO) \
		--log $(WORKLOAD_TRACE_QEMU_LOG) \
		--checker-bin $(WORKLOAD_ACCEPT_BIN)

check-workload-accept-kvm-2cpu: capture-workload-log-kvm-2cpu $(WORKLOAD_ACCEPT_BIN)
	python3 scripts/check_workload_acceptance.py \
		--backend kvm-workload \
		--scenario $(WORKLOAD_SCENARIO) \
		--log $(WORKLOAD_TRACE_KVM_LOG) \
		--checker-bin $(WORKLOAD_ACCEPT_BIN)

$(WORKLOAD_ACCEPT_BIN): $(WORKLOAD_ACCEPT_RUNNER) $(ACCEPT_CHECKER_DIR)/AwkernelWorkloadAcceptance.hs
	mkdir -p $(HASKELL_ACCEPT_TARGET_DIR)/workload-build
	$(GHC) $(GHCFLAGS) -i$(ACCEPT_CHECKER_DIR) $(WORKLOAD_ACCEPT_RUNNER) \
		-outputdir $(HASKELL_ACCEPT_TARGET_DIR)/workload-build \
		-odir $(HASKELL_ACCEPT_TARGET_DIR)/workload-build \
		-hidir $(HASKELL_ACCEPT_TARGET_DIR)/workload-build \
		-o $@

check-workload-accept-2cpu-all:
	@for scenario in $(WORKLOAD_SCENARIOS); do \
		$(MAKE) check-workload-accept-qemu-2cpu WORKLOAD_SCENARIO=$$scenario || exit $$?; \
		$(MAKE) check-workload-accept-kvm-2cpu WORKLOAD_SCENARIO=$$scenario || exit $$?; \
	done

check-workload-accept-contract:
	python3 -m unittest discover -s tests -p 'test_workload_acceptance_contract.py' -v

check-generic-random-workload-seeds: $(WORKLOAD_ACCEPT_BIN)
	python3 scripts/check_generic_random_workload_seeds.py \
		--checker-bin $(WORKLOAD_ACCEPT_BIN) \
		--awkernel-dir $(AWKERNEL_DIR) \
		$(GENERIC_RANDOM_RUNS)
