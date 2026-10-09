# make bw: SDRAM bandwidth gate (bwmodel.py) and the model's own regression (bwselftest.py).
# Included by the Makefile, which supplies HERE, RUNROOT, SEEDS, POCKET_ABS and the trace target.
BWSEEDS ?= $(SEEDS)
BW_MHZ  ?= 135.4752
BWTRACES ?= $(foreach s,$(BWSEEDS),$(RUNROOT)/trace_s$(s).txt $(if $(strip $(POCKET_ABS)),$(RUNROOT)/trace_pocket_s$(s).txt))

.PHONY: bw bwselftest
bw:
	@set -e; for s in $(BWSEEDS); do $(MAKE) --no-print-directory -f $(firstword $(MAKEFILE_LIST)) trace SEED=$$s; done; \
	python3 $(HERE)bwselftest.py $(RUNROOT); \
	python3 $(HERE)bwmodel.py --mhz 101.6064 $(BWARGS) $(BWTRACES) || true; \
	python3 $(HERE)bwmodel.py --mhz $(BW_MHZ) --max-util 0.8 $(BWARGS) $(BWTRACES)

bwselftest:
	@python3 $(HERE)bwselftest.py $(RUNROOT)
