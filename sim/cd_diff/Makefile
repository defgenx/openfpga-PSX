# CD differential test: frozen golden cd_top (patched copy, prep_golden.py) against rtl/cd_pocket*.vhd under nvc (VHDL-2008).
# Documentation: docs/pocket/CD.md ("Differential harness").
#
#   make golden        harness check: the golden against a renamed copy of itself, short run (must be 0 mismatches)
#   make diff          golden vs cd_pocket: SEEDS x COUNT random commands, DSEEDS directed scenarios, RT realtime scenarios
#   make gate          the gate run: >= 1 M random commands, the directed suites, the real-time suite, coverage required
#   make selftest      fault injection: output faults (every compared output) and RTL mutants of the golden copy
#   make clean
#
# SEEDS    random-suite shards (one nvc job per seed); COUNT: commands per shard
# KEEP=1   keep the generated files; JOBS: parallel make jobs (make -j)

HERE    := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
BUILD   := $(HERE)build
RUNROOT := $(HERE)run
NVC     := nvc --std=2008 --ieee-warnings=off
include $(HERE)../common/nvc.mk

SEEDS    ?= 1 2
COUNT    ?= 1500
DSCENS   ?= 0 1 2 3 4
RTSCENS  ?= 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21
RESETS   ?= 1
NVCGEN   ?=
GATE_SEEDS := 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26
GATE_COUNT := 65000
FIFO_CYCLES ?= 3000000
XCOUNT ?= 1500
XJOBS  ?= 1

POCKET_SRCS := $(RTL)/cd_xa_zigzag.vhd $(RTL)/cd_pocket_fifo.vhd $(RTL)/cd_pocket_xa.vhd $(RTL)/cd_pocket.vhd
-include $(HERE)pocket.mk
POCKET_ABS  := $(abspath $(POCKET_SRCS))
TB_SRCS     := $(HERE)../common/trace_cmp_pkg.vhd $(HERE)cd_diff_pkg.vhd $(HERE)tb_diff.vhd
GOLD_SRCS   := $(BUILD)/gsrc/cd_xa.vhd $(BUILD)/gsrc/cd_top.vhd

.PHONY: golden diff gate selftest fifo clean FORCE
.DEFAULT_GOAL := diff

$(BUILD)/gsrc/cd_top.vhd: $(HERE)prep_golden.py $(RTL)/cd_top.vhd $(RTL)/cd_xa.vhd
	mkdir -p $(BUILD)/gsrc
	python3 $(HERE)prep_golden.py $(RTL) $(BUILD)/gsrc
	touch $@
$(BUILD)/gsrc/cd_xa.vhd: $(BUILD)/gsrc/cd_top.vhd

# library gold: the memory models (entities work.dpram_dif) and the patched golden
$(BUILD)/gold/stamp: $(MEM_SRCS) $(RTL)/cd_xa_zigzag.vhd $(GOLD_SRCS) $(BUILD)/mem/stamp
	rm -rf $(BUILD)/gold; mkdir -p $(BUILD)/gold
	$(NVC) -H 256m --work=gold:$(BUILD)/gold/gold -L $(BUILD) -a --relaxed $(MEM_SRCS)
	$(NVC) -H 256m --work=gold:$(BUILD)/gold/gold -L $(BUILD) -a $(RTL)/cd_xa_zigzag.vhd $(GOLD_SRCS)
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

# self: the golden copy renamed to cd_pocket (harness check and mutants)
$(BUILD)/selfsrc/cd_pocket.vhd: $(BUILD)/gsrc/cd_top.vhd $(HERE)selftest.py
	mkdir -p $(BUILD)/selfsrc
	python3 $(HERE)selftest.py --rename $(BUILD)/gsrc $(BUILD)/selfsrc
$(eval $(call FLAVOUR,self,$(RTL)/cd_xa_zigzag.vhd $(BUILD)/selfsrc/cd_pocket_xa.vhd $(BUILD)/selfsrc/cd_pocket.vhd))
$(BUILD)/selfsrc/cd_pocket_xa.vhd: $(BUILD)/selfsrc/cd_pocket.vhd

# $(1) flavour, $(2) suite, $(3) n (seed or scenario)
define RUNJOB
$(RUNROOT)/$(1)/$(2)_s$(3)/status: $(BUILD)/$(1)/stamp FORCE
	@rm -rf $$(dir $$@); mkdir -p $$(dir $$@)
	@cd $$(dir $$@) && t0=`date +%s` && \
	{ $(NVC) -H 256m --work=work:$(BUILD)/$(1)/work -L $(BUILD)/gold -L $(BUILD)/$(1) -L $(BUILD) -e --no-save \
	    -g G_SUITE=$(2) -g G_SCEN=$(3) -g G_SEED=$(3) -g G_COUNT=$(CNT_$(2)) $(NVCGEN) tb_diff -r > run.log 2>&1; echo $$$$? > status; } ; \
	echo "done $(1) $(2) $(3): `grep '^RESULT' run.log | tail -1` (`expr \`date +%s\` - $$$$t0` s)"
endef
CNT_random   ?= $(COUNT)
CNT_directed ?= 2
CNT_realtime ?= 1
CNT_reset    ?= 40
CNT_smoke    ?= 1

# amputation generics: the golden is tied (peak, libcrypt) or the run is a smoke run (G_COMPARE=0: NO_XA, FIXED_CD_TIMING)
# $(1) name, $(2) suite, $(3) n, $(4) count, $(5) nvc generics
define XJOB
$(RUNROOT)/pocket/$(1)_$(2)_s$(3)/status: $(BUILD)/pocket/stamp FORCE
	@rm -rf $$(dir $$@); mkdir -p $$(dir $$@)
	@cd $$(dir $$@) && t0=`date +%s` && \
	{ $(NVC) -H 256m --work=work:$(BUILD)/pocket/work -L $(BUILD)/gold -L $(BUILD)/pocket -L $(BUILD) -e --no-save \
	    -g G_SUITE=$(2) -g G_SCEN=$(3) -g G_SEED=$(3) -g G_COUNT=$(4) $(5) tb_diff -r > run.log 2>&1; echo $$$$? > status; } ; \
	echo "done $(1) $(2) $(3): `grep '^RESULT' run.log | tail -1` (`expr \`date +%s\` - $$$$t0` s)"
RES_pocket += $(RUNROOT)/pocket/$(1)_$(2)_s$(3)/status
endef
ifneq ($(XJOBS),0)
$(eval $(call XJOB,nopeak,random,101,$(XCOUNT),-g G_DUT_NO_CD_PEAK=1))
$(eval $(call XJOB,nopeak,directed,3,2,-g G_DUT_NO_CD_PEAK=1))
$(eval $(call XJOB,nolib,random,102,$(XCOUNT),-g G_DUT_NO_LIBCRYPT=1))
$(eval $(call XJOB,nolib,directed,4,2,-g G_DUT_NO_LIBCRYPT=1))
$(eval $(call XJOB,noxa,random,103,$(XCOUNT),-g G_DUT_NO_XA=1 -g G_COMPARE=0))
$(eval $(call XJOB,noxa,directed,3,2,-g G_DUT_NO_XA=1 -g G_COMPARE=0))
$(eval $(call XJOB,fixed,random,104,$(XCOUNT),-g G_DUT_FIXED_CD_TIMING=1 -g G_COMPARE=0))
$(eval $(call XJOB,fixed,directed,2,2,-g G_DUT_FIXED_CD_TIMING=1 -g G_COMPARE=0))
endif

# jobs of a flavour: $(1) flavour, $(2) random seeds, $(3) directed scenarios, $(4) realtime scenarios, $(5) reset seeds
define JOBS
$(foreach s,$(2),$(eval $(call RUNJOB,$(1),random,$(s)))$(eval RES_$(1) += $(RUNROOT)/$(1)/random_s$(s)/status))
$(foreach s,$(3),$(eval $(call RUNJOB,$(1),directed,$(s)))$(eval RES_$(1) += $(RUNROOT)/$(1)/directed_s$(s)/status))
$(foreach s,$(4),$(eval $(call RUNJOB,$(1),realtime,$(s)))$(eval RES_$(1) += $(RUNROOT)/$(1)/realtime_s$(s)/status))
$(foreach s,$(5),$(eval $(call RUNJOB,$(1),reset,$(s)))$(eval RES_$(1) += $(RUNROOT)/$(1)/reset_s$(s)/status))
endef

ifeq ($(MAKECMDGOALS),gate)
$(eval $(call JOBS,pocket,$(GATE_SEEDS),$(DSCENS),$(RTSCENS),1 2 3 4))
else
$(eval $(call JOBS,pocket,$(SEEDS),$(DSCENS),$(RTSCENS),$(RESETS)))
endif
$(eval $(call JOBS,self,1,,,))

COVREQ := --require-coverage
GATE_MINS := --min random=1000000

golden: $(RES_self)
	@python3 $(HERE)summarize.py --min random=1000 $(dir $(RES_self))

diff: $(RES_pocket)
	@python3 $(HERE)summarize.py $(COVREQ) $(SUMARGS) $(dir $(RES_pocket))

gate: $(RES_pocket)
	@python3 $(HERE)summarize.py $(COVREQ) $(GATE_MINS) $(dir $(RES_pocket))

selftest: $(BUILD)/self/stamp
	@MEM_SRCS="$(MEM_SRCS)" python3 $(HERE)selftest.py $(BUILD) $(RUNROOT)/selftest

# cd_pocket_fifo against mem.SyncFifoFallThrough (data, parameter/response, output FIFO sizes) and mem.SyncFifo (ADPCM)
fifo: $(BUILD)/mem/stamp
	@rm -rf $(BUILD)/fifo; mkdir -p $(BUILD)/fifo
	@$(NVC) --work=work:$(BUILD)/fifo/work -L $(BUILD) -a $(COMMON)trace_cmp_pkg.vhd $(HERE)cd_diff_pkg.vhd $(RTL)/cd_pocket_fifo.vhd $(HERE)tb_fifo.vhd
	@for cfg in "12 8 1" "5 8 1" "10 32 1" "12 16 0"; do set -- $$cfg; \
	   $(NVC) --work=work:$(BUILD)/fifo/work -L $(BUILD) -e --no-save -g G_SIZEBITS=$$1 -g G_WIDTH=$$2 -g G_FALLTHROUGH=$$3 -g G_CYCLES=$(FIFO_CYCLES) tb_fifo -r 2>&1 \
	   | grep -E '^RESULT|^MISMATCH' | tee -a $(BUILD)/fifo/log | sed "s/^/fifo $$cfg: /"; done; \
	if grep -q 'FAIL' $(BUILD)/fifo/log; then echo 'FIFO FAIL'; exit 1; fi
	@echo "FIFO PASS"

clean:
	rm -rf $(BUILD) $(RUNROOT)
