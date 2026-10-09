# GTE differential test: golden gte vs gte_dut under nvc (VHDL-2008).
#
#   make golden                golden vs golden, smoke test of the harness
#   make selftest              fault injection: each injected fault must be reported exactly
#   make diff                  golden vs gte_serial (default SEEDS/COUNT: about 33k commands)
#   make -j8 gate              the Phase 1 gate run: ucode-check, then diff over GATE_SEEDS x GATE_COUNT
#                              with per-suite command minimums and full coverage required
#   make ucode-check           committed microcode ROM and pkg constants agree with rtl/gen/gte_ucode.py
#   make -j8 diff SEEDS="1 2 3 4" COUNT=250000     shards in parallel (COUNT per seed)
#   make clean
#
# SEEDS   one job per (suite, seed); each job runs in its own directory under run/
# COUNT   random-suite commands per seed (half uniform, half game-like)
# SUITES  directed edge reset cpu random boundary
# KEEP=1  keep the generated vector files

HERE    := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
BUILD   := $(HERE)build
RUNROOT := $(HERE)run
include $(HERE)../common/nvc.mk

-include $(HERE)serial.mk
-include $(HERE)div.mk
SERIAL_SRCS ?= ../../rtl/gte_serial.vhd

SEEDS  ?= 1
COUNT  ?= 20000
SUITES ?= directed edge reset cpu random boundary
GENARGS ?=
NVCGEN ?=
KEEP   ?=

# gte.vhd opens this literal name (two backslashes) in the current directory; each run
# links it to /dev/null so its per-command debug output is discarded.
DBGNAME := R:\\debug_gte_sim.txt

GOLD_SRCS   := $(RTL)/pGTE.vhd $(RTL)/gte_mac0.vhd $(RTL)/gte_mac123.vhd $(RTL)/gte_UNRDivide.vhd $(RTL)/gte.vhd
SERIAL_ABS  := $(foreach f,$(SERIAL_SRCS),$(abspath $(if $(filter /%,$(f)),$(f),$(HERE)$(f))))
TB_SRCS     := $(HERE)gte_dut.vhd $(HERE)tb_diff.vhd

# gate run: 8 x 125k random commands; minimums are exactly the commands each suite runs over these seeds
GATE_SEEDS := 21 22 23 24 25 26 27 28
GATE_COUNT := 125000
GATE_MINS  := --min directed=4096 --min edge=32000 --min reset=3587 --min cpu=63825 \
              --min random=1000000 --min boundary=7312

.PHONY: golden diff gate ucode-check selftest clean FORCE
.DEFAULT_GOAL := golden

$(BUILD)/golden/stamp: $(GOLD_SRCS) $(TB_SRCS) $(HERE)dut_golden.vhd
	rm -rf $(BUILD)/golden; mkdir -p $(BUILD)
	$(NVC) --work=work:$(BUILD)/golden -a $(GOLD_SRCS) $(HERE)gte_dut.vhd $(HERE)dut_golden.vhd $(HERE)tb_diff.vhd
	touch $@

$(BUILD)/serial/stamp: $(GOLD_SRCS) $(SERIAL_ABS) $(TB_SRCS) $(HERE)dut_serial.vhd
	rm -rf $(BUILD)/serial; mkdir -p $(BUILD)
	$(NVC) --work=work:$(BUILD)/serial -a $(GOLD_SRCS) $(SERIAL_ABS) $(HERE)gte_dut.vhd $(HERE)dut_serial.vhd $(HERE)tb_diff.vhd
	touch $@

# $(1) flavour, $(2) suite, $(3) seed
define RUNJOB
$(RUNROOT)/$(1)/$(2)_s$(3)/status: $(BUILD)/$(1)/stamp $(HERE)gen_vectors.py FORCE
	@rm -rf $$(dir $$@); mkdir -p $$(dir $$@)
	@cd $$(dir $$@) && ln -s /dev/null '$(DBGNAME)' && \
	python3 $(HERE)gen_vectors.py --suite $(2) --seed $(3) --count $(COUNT) $(GENARGS) --out vec.txt && \
	{ $(NVC) --work=work:$(BUILD)/$(1) -e --no-save -g G_VECFILE=vec.txt $(NVCGEN) tb_diff -r > run.log 2>&1; echo $$$$? > status; } ; \
	$(if $(KEEP),:,rm -f vec.txt); \
	echo "done $(1) $(2) seed $(3): `grep '^RESULT' run.log | tail -1`"
RESULTS_$(1) += $(RUNROOT)/$(1)/$(2)_s$(3)/status
endef

$(foreach fl,golden serial,$(foreach su,$(SUITES),$(foreach sd,$(SEEDS),$(eval $(call RUNJOB,$(fl),$(su),$(sd))))))

golden: $(RESULTS_golden)
	@python3 $(HERE)summarize.py $(COVREQ) $(dir $(RESULTS_golden))

# coverage is required only when the run has the suites that can reach every counter
COVREQ = $(if $(and $(filter edge,$(SUITES)),$(filter random,$(SUITES))),--require-coverage)

diff: $(RESULTS_serial)
	@python3 $(HERE)summarize.py $(COVREQ) $(SUMARGS) $(dir $(RESULTS_serial))

gate: ucode-check
	@$(MAKE) --no-print-directory -f $(firstword $(MAKEFILE_LIST)) diff SEEDS="$(GATE_SEEDS)" COUNT=$(GATE_COUNT) \
		SUITES="directed edge reset cpu random boundary" SUMARGS="$(GATE_MINS)"

ucode-check:
	@python3 $(RTL)/gen/gte_ucode.py --check

selftest: $(BUILD)/golden/stamp
	@python3 $(HERE)selftest.py $(BUILD)/golden $(RUNROOT)/selftest

clean:
	rm -rf $(BUILD) $(RUNROOT)
