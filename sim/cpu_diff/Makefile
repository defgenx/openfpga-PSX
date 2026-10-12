# CPU differential test: frozen cpu vs cpu_dut (golden or cpu_pocket) in lock step under nvc (VHDL-2008).
#
#   make golden                golden vs golden, smoke test of the harness
#   make selftest              fault injection: every injected fault must be reported
#   make diff                  golden vs cpu_pocket over SUITES x SEEDS (default: a short run)
#   make -j8 gate              the Phase 4 gate run: GATE_SEEDS x GATE_CYCLES per suite, coverage counters required,
#                              both NO_COP0_DEBUG settings
#   make clean
#
# SEEDS    one job per (suite, seed); each job runs in its own directory under run/; the testbench varies the memory latency range with the seed (seed mod 4)
# CYCLES   clk1x cycles per job
# SUITES   directed edge random exc cache gte reset stall wild (stall: heavy ce pauses, DMA stalls and interrupts)
# NODEBUG  1: NO_COP0_DEBUG generic true and the stimulus mask (no COP0 breakpoint registers); 0: full
# KEEP=1   keep the generated image files

HERE    := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
BUILD   := $(HERE)build
RUNROOT := $(HERE)run
NVC     := nvc --std=2008 --ieee-warnings=off
include $(HERE)../common/nvc.mk

SEEDS   ?= 1
CYCLES  ?= 60000
SUITES  ?= directed edge random exc cache gte reset stall wild
NODEBUG ?= 0
GENARGS ?=
NVCGEN  ?=
KEEP    ?=
POCKET_SRCS ?= $(RTL)/divider_pocket.vhd $(RTL)/cpu_pocket.vhd

COMMON_SRCS := $(RTL)/export.vhd $(COMMON)trace_cmp_pkg.vhd
GOLD_SRCS   := $(RTL)/divider.vhd $(RTL)/datacache.vhd $(BUILD)/cpu_dbg.vhd
TB_SRCS     := $(HERE)cpu_dut.vhd $(HERE)tb_diff.vhd

GATE_SEEDS  ?= 21 22 23 24 25 26 27 28
GATE_CYCLES ?= 400000
GATE_MINS   ?= --min-retires 1000000

.PHONY: golden diff gate selftest div clean FORCE
.DEFAULT_GOAL := golden

$(BUILD)/cpu_dbg.vhd: $(RTL)/cpu.vhd $(HERE)dbg_insert.awk
	mkdir -p $(BUILD)
	awk -f $(HERE)dbg_insert.awk $< > $@

$(BUILD)/golden/stamp: $(BUILD)/mem/stamp $(MEM_SRCS) $(COMMON_SRCS) $(GOLD_SRCS) $(TB_SRCS) $(HERE)dut_golden.vhd
	rm -rf $(BUILD)/golden; mkdir -p $(BUILD)
	$(call NVC_MEM_WORK,$(BUILD)/golden)
	$(NVC) -H 256m --work=work:$(BUILD)/golden -L $(BUILD) -a $(COMMON_SRCS) $(GOLD_SRCS) $(HERE)cpu_dut.vhd $(HERE)dut_golden.vhd $(HERE)tb_diff.vhd
	touch $@

$(BUILD)/pocket/stamp: $(BUILD)/mem/stamp $(MEM_SRCS) $(COMMON_SRCS) $(GOLD_SRCS) $(POCKET_SRCS) $(TB_SRCS) $(HERE)dut_pocket.vhd
	rm -rf $(BUILD)/pocket; mkdir -p $(BUILD)
	$(call NVC_MEM_WORK,$(BUILD)/pocket)
	$(NVC) -H 256m --work=work:$(BUILD)/pocket -L $(BUILD) -a $(COMMON_SRCS) $(GOLD_SRCS) $(POCKET_SRCS) $(HERE)cpu_dut.vhd $(HERE)dut_pocket.vhd $(HERE)tb_diff.vhd
	touch $@

# per-suite stimulus: generator suite, testbench generics
GEN_directed := directed
GEN_edge     := edge
GEN_random   := random
GEN_exc      := exc
GEN_cache    := cache
GEN_gte      := gte
GEN_reset    := random
GEN_stall    := exc
GEN_wild     := wild
GENX_reset   := --bp
GEN_smoke    := smoke
NVC_smoke    :=
NVC_directed := -g G_LAT_MAX=8 -g G_FIFO_THR=2 -g G_FIFO_DRAIN=10
NVC_edge     := -g G_LAT_MAX=6 -g G_CE_PCT=1
NVC_random   := -g G_LAT_MAX=10 -g G_SLOW_PCT=5 -g G_FIFO_THR=3 -g G_FIFO_DRAIN=8
NVC_exc      := -g G_LAT_MAX=6 -g G_IRQ_PERMILLE=12 -g G_IRQ_LEN=60
NVC_cache    := -g G_LAT_MAX=12 -g G_SLOW_PCT=8
NVC_gte      := -g G_LAT_MAX=6 -g G_GTE_MAX=30
NVC_reset    := -g G_RESET_EVERY=4000 -g G_LONGWAIT=3000
NVC_wild     := -g G_LAT_MAX=6 -g G_IRQ_PERMILLE=6
NVC_stall    := -g G_CE_PCT=25 -g G_DMA_PCT=15 -g G_IRQ_PERMILLE=25 -g G_IRQ_LEN=20 -g G_LAT_MAX=3 -g G_SLOW_PCT=1 -g G_FIFO_THR=2 -g G_FIFO_DRAIN=6

NDGEN  = $(if $(filter 1,$(NODEBUG)),--no-cop0-debug,)
NDNVC  = $(if $(filter 1,$(NODEBUG)),-g G_NO_COP0_DEBUG=true,-g G_NO_COP0_DEBUG=false)

MULT_directed := 4
MULT_edge     := 3
MULT_random   := 1
MULT_exc      := 1
MULT_cache    := 1
MULT_gte      := 1
MULT_reset    := 1
MULT_stall    := 1
MULT_wild     := 1
MULT_smoke    := 1
CYC = $(shell echo $$(( $(CYCLES) * $(MULT_$(1)) )))

# $(1) flavour, $(2) suite, $(3) seed
define RUNJOB
$(RUNROOT)/$(1)/$(2)_s$(3)/status: $(BUILD)/$(1)/stamp $(HERE)gen_prog.py $(HERE)isa.py FORCE
	@rm -rf $$(dir $$@); mkdir -p $$(dir $$@)
	@cd $$(dir $$@) && \
	python3 $(HERE)gen_prog.py --suite $(GEN_$(2)) --seed $(3) $(NDGEN) $(GENX_$(2)) $(GENARGS) --out image.txt 2> gen.log && \
	{ $(NVC) -H 256m --work=work:$(BUILD)/$(1) -L $(BUILD) -e --no-save -g G_IMAGE=image.txt -g G_CYCLES=$(call CYC,$(2)) -g G_SEED=$(3) \
	  $(NVC_$(2)) $(NDNVC) $(NVCGEN) tb_diff -r > run.log 2>&1; echo $$$$? > status; } ; \
	$(if $(KEEP),:,rm -f image.txt); \
	echo "done $(1) $(2) seed $(3): `grep '^STATS' run.log | tail -1`  `grep '^RESULT' run.log | tail -1`"
RESULTS_$(1) += $(RUNROOT)/$(1)/$(2)_s$(3)/status
endef

$(foreach fl,golden pocket,$(foreach su,$(SUITES),$(foreach sd,$(SEEDS),$(eval $(call RUNJOB,$(fl),$(su),$(sd))))))

COVREQ = $(if $(and $(filter directed,$(SUITES)),$(filter random,$(SUITES)),$(filter gte,$(SUITES)),$(filter exc,$(SUITES))),--require-coverage)

golden: $(RESULTS_golden)
	@python3 $(HERE)summarize.py $(COVREQ) $(SUMARGS) $(dir $(RESULTS_golden))

diff: $(RESULTS_pocket)
	@python3 $(HERE)summarize.py $(COVREQ) $(SUMARGS) $(dir $(RESULTS_pocket))

gate:
	@$(MAKE) --no-print-directory -f $(firstword $(MAKEFILE_LIST)) div
	@$(MAKE) --no-print-directory -f $(firstword $(MAKEFILE_LIST)) clean-runs
	@$(MAKE) --no-print-directory -f $(firstword $(MAKEFILE_LIST)) diff NODEBUG=0 SEEDS="$(GATE_SEEDS)" CYCLES=$(GATE_CYCLES) \
		SUMARGS="$(GATE_MINS) --label nodebug0"
	@$(MAKE) --no-print-directory -f $(firstword $(MAKEFILE_LIST)) clean-runs
	@$(MAKE) --no-print-directory -f $(firstword $(MAKEFILE_LIST)) diff NODEBUG=1 SEEDS="$(GATE_SEEDS)" CYCLES=$(GATE_CYCLES) \
		SUMARGS="$(GATE_MINS) --label nodebug1"
	@echo "GATE PASS (div, NO_COP0_DEBUG=false and true)"

.PHONY: clean-runs
clean-runs:
	rm -rf $(RUNROOT)

selftest: $(BUILD)/golden/stamp $(BUILD)/pocket/stamp
	@python3 $(HERE)selftest.py $(BUILD)/golden $(RUNROOT)/selftest

# divider_pocket against the golden divider at the clock cpu_pocket samples it
DIV_PAIRS ?= 1000000
div:
	rm -rf $(BUILD)/div; mkdir -p $(BUILD)
	$(NVC) --work=work:$(BUILD)/div -a $(RTL)/divider.vhd $(RTL)/divider_pocket.vhd $(HERE)tb_div.vhd
	cd $(BUILD) && $(NVC) -H 256m --work=work:div -e --no-save -g G_PAIRS=$(DIV_PAIRS) tb_div -r 2>&1 | grep "MISMATCH\|RESULT" | tee div.log; grep -q "mismatches=0 PASS" div.log
	cd $(BUILD) && ! $(NVC) -H 256m --work=work:div -e --no-save -g G_PAIRS=2000 -g G_LATENCY=34 tb_div -r 2>&1 | grep -q "mismatches=0 PASS" && echo "div selftest: sampling 1 clock early is reported"

clean:
	rm -rf $(BUILD) $(RUNROOT)
