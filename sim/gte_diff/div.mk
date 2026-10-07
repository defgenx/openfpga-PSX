# Exhaustive gte_serial_div vs gte_UNRDivide test. Standalone: make -f div.mk divtest
DIV_HERE := $(dir $(lastword $(MAKEFILE_LIST)))
DIV_RTL  := $(DIV_HERE)../../rtl
DIV_RUN  := $(DIV_HERE)run_divtest
DIV_SRC  := $(DIV_RTL)/pGTE.vhd $(DIV_RTL)/gte_UNRDivide.vhd $(DIV_RTL)/gte_serial_div.vhd $(DIV_HERE)tb_div.vhd
DIV_NVC  := nvc --std=2008

.PHONY: divtest divtest-selftest divtest-clean

divtest: $(DIV_SRC)
	@mkdir -p $(DIV_RUN)
	$(DIV_NVC) --work=work:$(DIV_RUN)/main -a $(DIV_SRC) -e tb_div -r 2>&1 | tee $(DIV_RUN)/main.log
	@grep -q "DIVTEST PASS" $(DIV_RUN)/main.log

divtest-selftest: $(DIV_SRC)
	@mkdir -p $(DIV_RUN)
	$(DIV_NVC) --work=work:$(DIV_RUN)/self -a $(DIV_SRC) -e -gselftest=true tb_div -r 2>&1 | tee $(DIV_RUN)/self.log
	@grep -q "DIVTEST-SELFTEST PASS" $(DIV_RUN)/self.log

divtest-clean:
	rm -rf $(DIV_RUN)
