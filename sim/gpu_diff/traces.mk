# Real-game traces: GP0/GP1 dumps recorded locally in DuckStation -> VRAM traces -> bwmodel.py.
# Included by Makefile. Uses its NVC, BUILD, RUNROOT, DBGNAMES, FLGEN_golden, FLGEN_pocket, NVCGEN, POCKET_ABS,
# BW_MHZ, BWARGS, TRACE_TAIL, HERE and the $(BUILD)/golden/stamp and $(BUILD)/pocket/stamp targets.
#
#   make trace-game TRACES="a.psxgpu b.psxgpu.zst"   dump -> run/game_<name>/vec.txt -> run/trace_game_<name>.txt
#                                                    (+ run/trace_pocket_game_<name>.txt when POCKET_SRCS is set)
#   make bw-game TRACES="..."                        trace-game, then bwmodel.py: a report at 101.6064 MHz, then
#                                                    --max-util 0.8 at BW_MHZ; report-only unless GAME_GATE=1
#   make gamevec-selftest                            converter self-test plus a harness run on a synthetic dump
#
# GAMEARGS  gpudump2vec.py options, e.g. GAMEARGS="--first-frame 100 --frames 3" (default: --frames 3)
# Dumps are read from the given paths; vectors, traces and logs stay under the gitignored run/ directory.

GAMEARGS ?= --frames 3
GAME_GATE ?=
GAMETAG   = $(basename $(basename $(notdir $(1))))
GAMENAMES = $(foreach t,$(TRACES),$(call GAMETAG,$(t)))
GAMETRACES = $(foreach n,$(GAMENAMES),$(RUNROOT)/trace_game_$(n).txt \
             $(if $(strip $(POCKET_ABS)),$(RUNROOT)/trace_pocket_game_$(n).txt))

.PHONY: trace-game bw-game gamevec-selftest

define newline


endef

# $(1) dump path, $(2) flavour, $(3) trace file prefix, $(4) generic naming the trace file
define GAMEJOB
	@set -e; n=$(call GAMETAG,$(1)); d=$(RUNROOT)/game_$(3)$$n; rm -rf $$d; mkdir -p $$d; cd $$d; \
	for x in $(DBGNAMES); do ln -s /dev/null "$$x"; done; \
	python3 $(HERE)gpudump2vec.py "$(abspath $(1))" --tail $(TRACE_TAIL) $(GAMEARGS) --out vec.txt; \
	$(NVC) -H 256m --work=work:$(BUILD)/$(2) -L $(BUILD) -e --no-save -g G_VECFILE=vec.txt $(FLGEN_$(2)) -g $(4)=trace.txt -g G_VRAM_BUSY=0 $(NVCGEN) tb_diff -r > run.log 2>&1 || true; \
	grep -q '^RESULT' run.log || { echo "trace-game $(2) $$n: simulator error"; tail -5 run.log; exit 1; }; \
	grep '^RESULT' run.log | tail -1; \
	test -s trace.txt || { echo "trace-game $(2) $$n: empty trace"; exit 1; }; \
	mv trace.txt $(RUNROOT)/trace_$(3)game_$$n.txt; \
	echo "trace: $(RUNROOT)/trace_$(3)game_$$n.txt `wc -l < $(RUNROOT)/trace_$(3)game_$$n.txt` accesses"
endef

trace-game: $(BUILD)/golden/stamp
	@test -n "$(strip $(TRACES))" || { echo 'usage: make trace-game TRACES="a.psxgpu b.psxgpu.zst"'; exit 2; }
	@for t in $(TRACES); do test -f "$$t" || { echo "trace-game: no such dump: $$t"; exit 2; }; done
	@echo "trace-game: $(GAMENAMES)"
	$(foreach t,$(TRACES),$(call GAMEJOB,$(t),golden,,G_TRACEFILE)$(newline))
ifneq ($(strip $(POCKET_ABS)),)
	@$(MAKE) --no-print-directory -f $(firstword $(MAKEFILE_LIST)) $(BUILD)/pocket/stamp
	$(foreach t,$(TRACES),$(call GAMEJOB,$(t),pocket,pocket_,G_TRACEFILE_DUT)$(newline))
endif

bw-game: trace-game
	@python3 $(HERE)bwmodel.py --mhz 101.6064 $(BWARGS) $(GAMETRACES) || true
	@python3 $(HERE)bwmodel.py --mhz $(BW_MHZ) --max-util 0.8 $(BWARGS) $(GAMETRACES) \
	  || { $(if $(GAME_GATE),exit 1,echo "bw-game: over 80%, report only (GAME_GATE=1 makes this fatal)"); }

gamevec-selftest: $(BUILD)/golden/stamp
	@python3 $(HERE)gpudump2vec.py --selftest
	@mkdir -p $(RUNROOT)/gamevec_selftest
	@python3 $(HERE)gpudump2vec.py --write-synth $(RUNROOT)/gamevec_selftest/synth.psxgpu
	@$(MAKE) --no-print-directory -f $(firstword $(MAKEFILE_LIST)) trace-game TRACES=$(RUNROOT)/gamevec_selftest/synth.psxgpu \
	  GAMEARGS="--frames 2" TRACE_TAIL=2000
