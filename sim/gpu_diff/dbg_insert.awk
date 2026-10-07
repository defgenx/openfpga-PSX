# Copies a gpu unit and adds concurrent statements after the architecture's first "begin" (see Makefile).
# -v poly=1 additionally adds the polygon state decodes read by span_probe_gold.vhd / span_dut_golden.vhd.
BEGIN { q = "\047" }
/^architecture/ { a = 1 }
a && !d && /^begin/ {
   if (poly) print "   signal dbg_prep, dbg_run, dbg_issue : std_logic;"
   print
   for (i = 1; i <= 6; i++)
      printf "   div%d.done <= %sZ%s; div%d.quotient <= (others => %sZ%s); div%d.remainder <= (others => %sZ%s);\n", i, q, q, i, q, q, i, q, q
   if (poly) {
      print "   dbg_prep  <= " q "1" q " when state = PREPARELINE else " q "0" q ";"
      print "   dbg_run   <= " q "1" q " when (state = REQUESTFIRST or state = REQUESTLINE or state = PROCPIXELS) else " q "0" q ";"
      print "   dbg_issue <= " q "1" q " when state = ISSUE else " q "0" q ";"
   }
   d = 1
   next
}
# poly: integer(natural) > unsigned compare with a negative xStart is a range error under nvc; same truth value without it
poly { sub(/to_integer\(xStart\(43 downto 32\)\) > drawingAreaRight/, "(xStart(43) = " q "0" q " and unsigned(xStart(42 downto 32)) > drawingAreaRight)") }
{ print }
