# SPU differential test: frozen golden spu (patched copy, prep_golden.py) against rtl/spu_pocket*.vhd under nvc (VHDL-2008).
# Documentation: docs/pocket/SPU.md ("Differential harness").
#
#   make golden        harness check: the golden against a renamed copy of itself (must be 0 mismatches)
#   make diff          golden vs spu_pocket: SEEDS random, SCENS directed, WSEEDS wild, RSEEDS reset runs
#   make gate          the gate run: GATE_SEEDS of every suite, coverage required, minimum sample counts
#   make bw            SDRAM request counts per 1 ms window, 4x and 1x pitch on every voice, golden against spu_pocket
#   make selftest      fault injection: output faults and golden mutants, each must be reported
#   make clean
#
# COUNT: samples (768 clk1x) per run; JOBS: parallel make jobs (make -jN); NVCGEN: extra nvc generics
# Suites: random directed wild (random ce/cpuPaused, dense bus traffic) reset (mid-run resets) bw (all voices keyed on)
# DUT generics: NO_REVERB (G_NO_REVERB; the golden is tied REVERBOFF = G_NO_REVERB), L1_CACHE (G_L1: reads are not compared,
# fixed latency G_LATMIN).

HERE    := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
BUILD   := $(HERE)build
RUNROOT := $(HERE)run
NVC     := nvc --std=2008 --ieee-warnings=off
include $(HERE)../common/nvc.mk

SEEDS   ?= 1 2 3
COUNT   ?= 160
SCENS   ?= 0 1 2 3 4 5 6
WSEEDS  ?= 1 2
RSEEDS  ?= 1 2
NVCGEN  ?=
BWCOUNT ?= 200
GATE_SEEDS := 11 12 13 14 15 16 17 18
GATE_COUNT := 400

POCKET_SRCS ?= $(RTL)/spu_pocket_gauss.vhd $(RTL)/spu_pocket_sdp.vhd $(RTL)/spu_pocket_fifo.vhd $(RTL)/spu_pocket_ram.vhd $(RTL)/spu_pocket.vhd
-include $(HERE)pocket.mk
POCKET_ABS  := $(abspath $(POCKET_SRCS))
TB_SRCS     := $(COMMON)trace_cmp_pkg.vhd $(HERE)spu_diff_pkg.vhd $(HERE)spu_ram_model.vhd $(HERE)tb_diff.vhd
GOLD_SRCS   := $(BUILD)/gsrc/spu.vhd

.PHONY: golden diff gate bw selftest clean FORCE
.DEFAULT_GOAL := diff

$(BUILD)/gsrc/spu.vhd: $(HERE)prep_golden.py $(RTL)/spu.vhd
	mkdir -p $(BUILD)/gsrc
	python3 $(HERE)prep_golden.py $(RTL) $(BUILD)/gsrc
	touch $@

# library gold: the memory models (entities work.dpram_dif) and the patched golden
$(BUILD)/gold/stamp: $(MEM_SRCS) $(RTL)/spu_ram.vhd $(RTL)/spu_gauss.vhd $(GOLD_SRCS) $(BUILD)/mem/stamp $(BUILD)/altera_mf/stamp
	rm -rf $(BUILD)/gold; mkdir -p $(BUILD)/gold
	$(NVC) -H 256m --work=gold:$(BUILD)/gold/gold -L $(BUILD) -a --relaxed $(MEM_SRCS)
	$(NVC) -H 256m --work=gold:$(BUILD)/gold/gold -L $(BUILD) -a $(RTL)/spu_ram.vhd $(RTL)/spu_gauss.vhd $(GOLD_SRCS)
	touch $@

# $(1) flavour, $(2) DUT sources. The DUT library is named dut; the testbench library is work.
define FLAVOUR
$(BUILD)/$(1)/stamp: $(BUILD)/gold/stamp $(MEM_SRCS) $(2) $(TB_SRCS) $(BUILD)/mem/stamp
	rm -rf $(BUILD)/$(1); mkdir -p $(BUILD)/$(1)
	$(NVC) -H 256m --work=dut:$(BUILD)/$(1)/dut -L $(BUILD) -a --relaxed $(MEM_SRCS)
	$(NVC) -H 256m --work=dut:$(BUILD)/$(1)/dut -L $(BUILD) -a $(2)
	$(NVC) -H 256m --work=work:$(BUILD)/$(1)/work -L $(BUILD)/gold -L $(BUILD)/$(1) -L $(BUILD) -a $(TB_SRCS)
	touch $$@
endef
$(eval $(call FLAVOUR,pocket,$(POCKET_ABS)))

# self: the golden copy renamed to spu_pocket (harness check and mutants)
$(BUILD)/selfsrc/spu_pocket.vhd: $(BUILD)/gsrc/spu.vhd $(HERE)selftest.py
	mkdir -p $(BUILD)/selfsrc
	python3 $(HERE)selftest.py --rename $(BUILD)/gsrc $(BUILD)/selfsrc
$(eval $(call FLAVOUR,self,$(RTL)/spu_ram.vhd $(RTL)/spu_gauss.vhd $(BUILD)/selfsrc/spu_pocket.vhd))

# $(1) flavour, $(2) job name, $(3) suite, $(4) scenario, $(5) seed, $(6) samples, $(7) extra nvc generics
define RUNJOB
$(RUNROOT)/$(1)/$(2)/status: $(BUILD)/$(1)/stamp FORCE
	@rm -rf $$(dir $$@); mkdir -p $$(dir $$@)
	@cd $$(dir $$@) && t0=`date +%s` && \
	{ $(NVC) -H 256m --work=work:$(BUILD)/$(1)/work -L $(BUILD)/gold -L $(BUILD)/$(1) -L $(BUILD) -e --no-save \
	    -g G_SUITE=$(3) -g G_SCEN=$(4) -g G_SEED=$(5) -g G_COUNT=$(6) $(7) $(NVCGEN) tb_diff -r > run.log 2>&1; echo $$$$? > status; } ; \
	echo "done $(1) $(2): `grep '^RESULT' run.log | tail -1` (`expr \`date +%s\` - $$$$t0` s)"
RES_$(1) += $(RUNROOT)/$(1)/$(2)/status
endef

# jobs of a flavour: $(1) flavour, $(2) random seeds, $(3) directed scenarios, $(4) wild seeds, $(5) reset seeds, $(6) samples
define JOBS
$(foreach s,$(2),$(eval $(call RUNJOB,$(1),random_s$(s),random,0,$(s),$(6),)))
$(foreach s,$(3),$(eval $(call RUNJOB,$(1),directed_s$(s),directed,$(s),$(shell expr 100 + $(s)),$(6),)))
$(foreach s,$(4),$(eval $(call RUNJOB,$(1),wild_s$(s),wild,0,$(shell expr 200 + $(s)),$(6),)))
$(foreach s,$(5),$(eval $(call RUNJOB,$(1),reset_s$(s),reset,0,$(shell expr 300 + $(s)),$(6),)))
endef

# reverb-on exactness (DUT NO_REVERB = false, golden REVERBOFF = 0) when REV=1
ifeq ($(MAKECMDGOALS),gate)
$(eval $(call JOBS,pocket,$(GATE_SEEDS),$(SCENS),$(GATE_SEEDS),$(GATE_SEEDS),$(GATE_COUNT)))
else
$(eval $(call JOBS,pocket,$(SEEDS),$(SCENS),$(WSEEDS),$(RSEEDS),$(COUNT)))
endif
XCNT := $(COUNT)
ifeq ($(MAKECMDGOALS),gate)
REV  := 1
L1   := 1
XCNT := $(GATE_COUNT)
endif
ifeq ($(REV),1)
$(eval $(call RUNJOB,pocket,rev_random_s1,random,4,401,$(XCNT),-g G_NO_REVERB=0))
$(eval $(call RUNJOB,pocket,rev_directed_s4,directed,4,404,$(XCNT),-g G_NO_REVERB=0))
$(eval $(call RUNJOB,pocket,rev_wild_s1,wild,0,405,$(XCNT),-g G_NO_REVERB=0))
$(eval $(call RUNJOB,pocket,rev_directed_s0,directed,0,406,$(XCNT),-g G_NO_REVERB=0))
$(eval $(call RUNJOB,pocket,rev_directed_s6,directed,6,407,$(XCNT),-g G_NO_REVERB=0))
$(eval $(call RUNJOB,pocket,rev_reset_s1,reset,0,408,$(XCNT),-g G_NO_REVERB=0))
$(eval $(call RUNJOB,pocket,rev_off_random_s1,random,0,409,$(XCNT),-g G_NO_REVERB=0 -g G_REVOFF=1))
$(eval $(call RUNJOB,pocket,rev_off_directed_s4,directed,4,410,$(XCNT),-g G_NO_REVERB=0 -g G_REVOFF=1))
endif
ifeq ($(L1),1)
$(eval $(call RUNJOB,pocket,l1_random_s1,random,0,501,$(XCNT),-g G_L1=1 -g G_LATMIN=1 -g G_LATMAX=1))
$(eval $(call RUNJOB,pocket,l1_directed_s5,directed,5,505,$(XCNT),-g G_L1=1 -g G_LATMIN=1 -g G_LATMAX=1))
$(eval $(call RUNJOB,pocket,l1_directed_s2,directed,2,502,$(XCNT),-g G_L1=1 -g G_LATMIN=1 -g G_LATMAX=1))
$(eval $(call RUNJOB,pocket,l1_directed_s3,directed,3,503,$(XCNT),-g G_L1=1 -g G_LATMIN=1 -g G_LATMAX=1))
$(eval $(call RUNJOB,pocket,l1_wild_s1,wild,0,504,$(XCNT),-g G_L1=1 -g G_LATMIN=1 -g G_LATMAX=1))
$(eval $(call RUNJOB,pocket,l1_directed_s0,directed,0,506,$(XCNT),-g G_L1=1 -g G_LATMIN=1 -g G_LATMAX=1))
$(eval $(call RUNJOB,pocket,l1_directed_s6,directed,6,507,$(XCNT),-g G_L1=1 -g G_LATMIN=1 -g G_LATMAX=1))
$(eval $(call RUNJOB,pocket,l1_reset_s1,reset,0,508,$(XCNT),-g G_L1=1 -g G_LATMIN=1 -g G_LATMAX=1))
$(eval $(call RUNJOB,pocket,l1_rev_directed_s4,directed,4,509,$(XCNT),-g G_L1=1 -g G_NO_REVERB=0 -g G_LATMIN=1 -g G_LATMAX=1))
endif
$(eval $(call RUNJOB,pocket,slow_s1,random,0,701,$(XCNT),-g G_LATMIN=3 -g G_LATMAX=12))
$(eval $(call RUNJOB,pocket,overrun_s1,random,0,702,$(XCNT),-g G_LATMIN=11 -g G_LATMAX=12))
$(eval $(call RUNJOB,pocket,overrun_s2,wild,0,703,$(XCNT),-g G_LATMIN=11 -g G_LATMAX=12))
$(eval $(call JOBS,self,1,,,,60))

COVREQ := --require-coverage
GATE_MINS := --min random=1000 --min directed=1000 --min wild=1000 --min reset=1000

golden: $(RES_self)
	@python3 $(HERE)summarize.py --names $(BUILD)/gsrc/cov_names.txt --min random=50 $(dir $(RES_self))

diff: $(RES_pocket)
	@python3 $(HERE)summarize.py --names $(BUILD)/gsrc/cov_names.txt $(COVREQ) $(SUMARGS) $(dir $(RES_pocket))

gate: $(RES_pocket)
	@python3 $(HERE)summarize.py --names $(BUILD)/gsrc/cov_names.txt $(COVREQ) $(GATE_MINS) $(dir $(RES_pocket))

selftest: $(BUILD)/self/stamp
	@MEM_SRCS="$(MEM_SRCS)" python3 $(HERE)selftest.py $(BUILD) $(RUNROOT)/selftest

BWJOBS := bw4 bw1 bw4s bw1s
$(eval $(call RUNJOB,pocket,bw4,bw,0,601,$(BWCOUNT),$(BWGEN)))
$(eval $(call RUNJOB,pocket,bw1,bw,1,602,$(BWCOUNT),$(BWGEN)))
$(eval $(call RUNJOB,pocket,bw4s,bw,0,603,$(BWCOUNT),-g G_L1=1 -g G_SAMPLE_ONLY=1 -g G_LATMIN=1 -g G_LATMAX=8))
$(eval $(call RUNJOB,pocket,bw1s,bw,1,604,$(BWCOUNT),-g G_L1=1 -g G_SAMPLE_ONLY=1 -g G_LATMIN=1 -g G_LATMAX=8))
RES_pocket := $(filter-out %/bw4/status %/bw1/status %/bw4s/status %/bw1s/status,$(RES_pocket))
bw: $(RUNROOT)/pocket/bw4/status $(RUNROOT)/pocket/bw1/status $(RUNROOT)/pocket/bw4s/status $(RUNROOT)/pocket/bw1s/status
	@python3 $(HERE)summarize.py --bw $(RUNROOT)/pocket/bw4 $(RUNROOT)/pocket/bw1 $(RUNROOT)/pocket/bw4s $(RUNROOT)/pocket/bw1s

clean:
	rm -rf $(BUILD) $(RUNROOT)
