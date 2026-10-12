# DMA differential test: golden rtl/dma.vhd vs rtl/dma_pocket.vhd under nvc (VHDL-2008), same inputs, every output
# compared every clk3x cycle.
#
#   make golden                golden vs golden, smoke test of the harness
#   make diff                  golden vs dma_pocket (default SEEDS/COUNT)
#   make -j8 gate              the gate run: GATE_SEEDS x every suite, with per-suite compare minimums and full coverage
#   make selftest              fault injection and RTL mutants: each must be reported
#   make clean
#
# SEEDS   one job per (suite, seed); each job runs in its own directory under run/
# COUNT   scenarios per random-like job
# SUITES  directed random wild boundary turbo reset contention (wild runs with G_MODE=1: random cpuPaused/ce/canDMA)
# KEEP=1  keep the generated vector files

HERE    := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
BUILD   := $(HERE)build
RUNROOT := $(HERE)run
NVC     := nvc --std=2008 --ieee-warnings=off
include $(HERE)../common/nvc.mk

SEEDS  ?= 1 2
COUNT  ?= 60
SUITES ?= directed random wild boundary turbo reset contention
KEEP   ?=
NVCGEN ?=

# The golden as simulated: rtl/dma.vhd with two sim-only patches that make nvc follow the synthesised widths
# (integer ranges are not enforced in hardware): REP_refresh wraps at 128 (7 bits), requestedDwords/requiredDwords
# are 17 bits (a burst may overshoot 65536).
GOLD_RTL   := $(BUILD)/dma_sim.vhd
POCKET_RTL := $(RTL)/dma_pocket.vhd
TB_SRCS    := $(COMMON)trace_cmp_pkg.vhd $(HERE)dma_diff_pkg.vhd $(HERE)dma_side.vhd $(HERE)tb_dma.vhd

GATE_SEEDS := 1 2 3 4 5 6
GATE_COUNT := 150
GATE_MINS  := --min directed=2000000 --min random=2000000 --min wild=2000000 --min boundary=1000000 --min turbo=1000000 --min reset=1000000 --min contention=1000000

.PHONY: golden diff gate selftest clean FORCE
.DEFAULT_GOAL := golden

$(BUILD)/dma_sim.vhd: $(RTL)/dma.vhd
	mkdir -p $(BUILD)
	sed -e 's/REP_refresh <= REP_refresh + 1;/REP_refresh <= (REP_refresh + 1) mod 128;/' \
	    -e 's/\(signal re[a-z]*Dwords *: integer range 0 to\) 65536;/\1 131071;/' $< > $@
	test `grep -c 'mod 128' $@` -eq 2 && test `grep -c '131071' $@` -eq 2

# $(1) flavour (build directory name), $(2) extra RTL sources
define BUILDFLAVOUR
$(BUILD)/$(1)/stamp: $(BUILD)/mem/stamp $(GOLD_RTL) $(2) $(TB_SRCS)
	rm -rf $(BUILD)/$(1); mkdir -p $(BUILD)
	$(NVC) -H 256m --work=work:$(BUILD)/$(1) -L $(BUILD) -a $(GOLD_RTL) $(2)
	$(NVC) -H 256m --work=work:$(BUILD)/$(1) -L $(BUILD) -a --relaxed $(TB_SRCS)
	touch $$@
endef
$(eval $(call BUILDFLAVOUR,golden,))
$(eval $(call BUILDFLAVOUR,pocket,$(POCKET_RTL)))

MODE_wild := 1
MODE_directed := 0
MODE_random := 0
MODE_boundary := 0
MODE_turbo := 0
MODE_reset := 0
MODE_contention := 0
MODE_smoke := 0

# $(1) flavour, $(2) suite, $(3) seed
define RUNJOB
$(RUNROOT)/$(1)/$(2)_s$(3)/status: $(BUILD)/$(1)/stamp $(HERE)gen_vectors.py FORCE
	@rm -rf $$(dir $$@); mkdir -p $$(dir $$@)
	@cd $$(dir $$@) && python3 $(HERE)gen_vectors.py --suite $(2) --seed $(3) --count $(COUNT) --out vec.txt 2>/dev/null && \
	{ $(NVC) -H 256m --work=work:$(BUILD)/$(1) -L $(BUILD) -e --no-save -g G_VECFILE=vec.txt -g G_DUT=$(if $(filter golden,$(1)),golden,pocket) \
	  -g G_MODE=$(MODE_$(2)) -g G_SEED=$(3) $(NVCGEN) tb_dma -r > run.log 2>&1; echo $$$$? > status; } ; \
	$(if $(KEEP),:,rm -f vec.txt); \
	echo "done $(1) $(2) seed $(3): `grep '^RESULT' run.log | tail -1`"
RESULTS_$(1) += $(RUNROOT)/$(1)/$(2)_s$(3)/status
endef
$(foreach fl,golden pocket,$(foreach su,$(SUITES),$(foreach sd,$(SEEDS),$(eval $(call RUNJOB,$(fl),$(su),$(sd))))))

COVREQ = $(if $(and $(filter directed,$(SUITES)),$(filter random,$(SUITES)),$(filter wild,$(SUITES)),$(filter reset,$(SUITES)),$(filter turbo,$(SUITES))),--require-coverage)

golden: $(RESULTS_golden)
	@python3 $(HERE)summarize.py $(COVREQ) $(dir $(RESULTS_golden))

diff: $(RESULTS_pocket)
	@python3 $(HERE)summarize.py $(COVREQ) $(SUMARGS) $(dir $(RESULTS_pocket))

gate:
	@$(MAKE) --no-print-directory -f $(firstword $(MAKEFILE_LIST)) diff SEEDS="$(GATE_SEEDS)" COUNT=$(GATE_COUNT) \
		SUITES="directed random wild boundary turbo reset contention" SUMARGS="$(GATE_MINS)"

selftest: $(BUILD)/golden/stamp $(BUILD)/mem/stamp
	@python3 $(HERE)selftest.py $(BUILD) $(RUNROOT)/selftest

clean:
	rm -rf $(BUILD) $(RUNROOT)
