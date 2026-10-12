# GPU differential test: frozen gpu vs gpu_dut under nvc (VHDL-2008), one VRAM model per side.
#
#   make golden                golden vs golden, smoke test of the harness
#   make video                 golden vs gpu_pocket video outputs, cycle by cycle, one display mode per seed (VSEEDS)
#   make selftest              fault injection: each injected fault must be reported exactly
#   make diff                  golden vs gpu_pocket (needs POCKET_SRCS, see pocket.mk)
#   make trace SEED=n          VRAM access trace of the game-like suite: golden -> run/trace_sN.txt,
#                              gpu_pocket (when POCKET_SRCS is set) -> run/trace_pocket_sN.txt; fails if a run has no RESULT
#   make bw SEEDS="1 2 3"      bandwidth model over the traces (rule and options in bw.mk)
#   make clean
#
# SEEDS   one job per (suite, seed); each job runs in its own directory under run/
# COUNT   primitives per seed in the random suite (half uniform, half game-like); game suite: COUNT game-like
# SUITES  directed edge random (also: game, smoke)
# GENARGS extra gen_vectors.py arguments
# NVCGEN  extra nvc -g generics, e.g. NVCGEN="-g G_REPRODUCIBLEGPUTIMING=1 -g G_TIMING_STRICT=false"
# KEEP=1  keep the generated vector files

HERE    := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
BUILD   := $(HERE)build
RUNROOT := $(HERE)run
NVC     := nvc --std=2008 --ieee-warnings=off
include $(HERE)../common/nvc.mk

-include $(HERE)pocket.mk
POCKET_SRCS ?=

SEEDS  ?= 1 2
SEED   ?= 1
COUNT  ?= 2000
SUITES ?= directed edge random
GENARGS ?=
NVCGEN ?=
KEEP   ?=
TRACE_TAIL ?= 600000   # idle clk1x cycles after the game-like stream so video scan-out reads appear in the trace

# The GPU opens these literal names (two backslashes) in the current directory; each run
# links them to /dev/null so the per-event debug output is discarded.
DBGNAMES := 'R:\\debug_gpufifo_sim.txt' 'R:\\debug_pixel_sim.txt' 'R:\\debug_vram2cpu_sim.txt'

# VRAM-side memories: library mem and, via NVC_MEM_WORK, work (MEM_SRCS, nvc.mk).
# gpu_poly.vhd and gpu_line.vhd are analysed as build/*_dbg.vhd: the same files plus concurrent statements.
#  - both: the divN ports are inout records of which the unit drives only start/dividend/divisor; the done/quotient/
#    remainder elements get a 'Z' driver so the port does not contribute its initial 'U' (a simulator that creates a
#    driver for the whole port, as nvc does, otherwise resolves them to 'U')
#  - poly: dbg_prep/dbg_run/dbg_issue decode the state machine, whose type cannot be named from outside
GPU_SRCS  := $(addprefix $(RTL)/,divider.vhd pGPU.vhd pGPU_pocket.vhd mul32u.vhd mul9s.vhd gpu_fillVram.vhd gpu_cpu2vram.vhd \
             gpu_vram2vram.vhd gpu_vram2cpu.vhd) $(BUILD)/gpu_line_dbg.vhd $(addprefix $(RTL)/,gpu_rect.vhd) $(BUILD)/gpu_poly_dbg.vhd \
             $(addprefix $(RTL)/,gpu_pixelpipeline.vhd \
             gpu_overlay.vhd gpu_dither.vhd gpu_videoout_async.vhd gpu_videoout_sync.vhd gpu_crosshair.vhd \
             justifier_sensor.vhd gpu_videoout.vhd gpu.vhd)
POCKET_ABS := $(foreach f,$(POCKET_SRCS),$(abspath $(if $(filter /%,$(f)),$(f),$(HERE)$(f))))
TB_SRCS   := $(HERE)gpu_diff_pkg.vhd $(HERE)gpu_span_pkg.vhd $(HERE)gpu_dut.vhd $(HERE)vram_model.vhd $(HERE)gpu_side.vhd \
             $(HERE)span_probe.vhd $(HERE)span_probe_gold.vhd $(HERE)tb_diff.vhd
# per-flavour generics: the DUT's cycle counts may differ from the golden's
FLGEN_golden :=
FLGEN_pocket := -g G_TIMING_STRICT=false

.PHONY: golden diff selftest trace bw clean FORCE
.DEFAULT_GOAL := golden

$(BUILD)/gpu_poly_dbg.vhd: AWKFLAGS := -v poly=1

# $(1) flavour, $(2) DUT architecture file, $(3) extra sources, $(4) DUT span probe architecture
define BUILDFLAVOUR
$(BUILD)/$(1)/stamp: $(BUILD)/mem/stamp $(MEM_SRCS) $(GPU_SRCS) $(TB_SRCS) $(2) $(4) $(3)
	rm -rf $(BUILD)/$(1); mkdir -p $(BUILD)
	$(call NVC_MEM_WORK,$(BUILD)/$(1))
	$(NVC) -H 256m --work=work:$(BUILD)/$(1) -L $(BUILD) -a $(GPU_SRCS) $(3) $(HERE)gpu_diff_pkg.vhd $(HERE)gpu_span_pkg.vhd $(HERE)gpu_dut.vhd $(2) \
	       $(HERE)vram_model.vhd $(HERE)gpu_side.vhd $(HERE)span_probe.vhd $(HERE)span_probe_gold.vhd $(4) $(HERE)tb_diff.vhd
	touch $$@
endef
$(eval $(call BUILDFLAVOUR,golden,$(HERE)dut_golden.vhd,,$(HERE)span_dut_golden.vhd))
ifneq ($(strip $(POCKET_ABS)),)
$(eval $(call BUILDFLAVOUR,pocket,$(HERE)dut_pocket.vhd,$(POCKET_ABS),$(HERE)span_dut_pocket.vhd))
endif

# $(1) flavour, $(2) suite, $(3) seed
define RUNJOB
$(RUNROOT)/$(1)/$(2)_s$(3)/status: $(BUILD)/$(1)/stamp $(HERE)gen_vectors.py FORCE
	@rm -rf $$(dir $$@); mkdir -p $$(dir $$@)
	@cd $$(dir $$@) && for n in $(DBGNAMES); do ln -s /dev/null "$$$$n"; done && \
	python3 $(HERE)gen_vectors.py --suite $(2) --seed $(3) --count $(COUNT) $(GENARGS) --out vec.txt && \
	t0=`date +%s` && \
	{ $(NVC) -H 256m --work=work:$(BUILD)/$(1) -L $(BUILD) -e --no-save -g G_VECFILE=vec.txt $(FLGEN_$(1)) $(NVCGEN) tb_diff -r > run.log 2>&1; echo $$$$? > status; } ; \
	echo $$$$((`date +%s` - t0)) > elapsed; \
	$(if $(KEEP),:,rm -f vec.txt); \
	echo "done $(1) $(2) seed $(3): `grep '^RESULT' run.log | tail -1` (`cat elapsed` s)"
RESULTS_$(1) += $(RUNROOT)/$(1)/$(2)_s$(3)/status
endef

$(foreach fl,golden pocket,$(foreach su,$(SUITES),$(foreach sd,$(SEEDS),$(eval $(call RUNJOB,$(fl),$(su),$(sd))))))

# coverage is required only when the run has the suites that can reach every counter
COVREQ = $(if $(and $(filter directed,$(SUITES)),$(filter random,$(SUITES))),--require-coverage)

golden: $(RESULTS_golden)
	@python3 $(HERE)summarize.py $(COVREQ) $(SUMARGS) $(dir $(RESULTS_golden))

diff:
ifeq ($(strip $(POCKET_ABS)),)
	@echo "POCKET_SRCS is empty: set it (see pocket.mk) to build the gpu_pocket flavour"; exit 2
else
	@$(MAKE) --no-print-directory -f $(firstword $(MAKEFILE_LIST)) diff-run
endif

.PHONY: video
VSEEDS ?= 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16
video:
	@$(MAKE) --no-print-directory -f $(firstword $(MAKEFILE_LIST)) diff SUITES=video SEEDS="$(VSEEDS)"

.PHONY: diff-run
diff-run: $(RESULTS_pocket)
	@python3 $(HERE)summarize.py $(COVREQ) $(SUMARGS) $(dir $(RESULTS_pocket))

# $(1) flavour, $(2) output name, $(3) generic that names the trace file of that flavour's side
define TRACEJOB
	@set -e; d=$(RUNROOT)/trace_$(2)s$(SEED); rm -rf $$d; mkdir -p $$d; cd $$d; \
	for n in $(DBGNAMES); do ln -s /dev/null "$$n"; done; \
	python3 $(HERE)gen_vectors.py --suite game --seed $(SEED) --count $(COUNT) --tail $(TRACE_TAIL) $(GENARGS) --out vec.txt; \
	$(NVC) -H 256m --work=work:$(BUILD)/$(1) -L $(BUILD) -e --no-save -g G_VECFILE=vec.txt $(FLGEN_$(1)) -g $(3)=trace.txt -g G_VRAM_BUSY=0 $(NVCGEN) tb_diff -r > run.log 2>&1 || true; \
	grep -q '^RESULT' run.log || { echo "trace $(1) seed $(SEED): simulator error"; tail -5 run.log; exit 1; }; \
	grep '^RESULT' run.log | tail -1; \
	test -s trace.txt || { echo "trace $(1) seed $(SEED): empty trace"; exit 1; }; \
	mv trace.txt $(RUNROOT)/trace_$(2)s$(SEED).txt; \
	echo "trace: $(RUNROOT)/trace_$(2)s$(SEED).txt `wc -l < $(RUNROOT)/trace_$(2)s$(SEED).txt` accesses"
endef

trace: $(BUILD)/golden/stamp
	$(call TRACEJOB,golden,,G_TRACEFILE)
ifneq ($(strip $(POCKET_ABS)),)
	@$(MAKE) --no-print-directory -f $(firstword $(MAKEFILE_LIST)) trace-pocket SEED=$(SEED)

.PHONY: trace-pocket
trace-pocket: $(BUILD)/pocket/stamp
	$(call TRACEJOB,pocket,pocket_,G_TRACEFILE_DUT)
endif

selftest: $(BUILD)/golden/stamp
	@python3 $(HERE)selftest.py $(BUILD)/golden $(BUILD) $(RUNROOT)/selftest

clean:
	rm -rf $(BUILD) $(RUNROOT)

# Included last: everything above (variables, flavour/run rules, trace) is visible to them.
-include $(HERE)bw.mk $(HERE)traces.mk
