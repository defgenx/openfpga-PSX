# Copy of rtl/cpu.vhd with integer decodes of its enumeration signals, for the testbench's coverage probes.
/^architecture/ { a = 1 }
a && !d && /^begin/ {
   print "   signal dbg_hc, dbg_est, dbg_lt, dbg_hw : integer := 0;"
   print
   print "   dbg_hc  <= CPU_HILOCALC'pos(hilocalc);"
   print "   dbg_est <= CPU_EXESTALLTYPE'pos(executeStalltype);"
   print "   dbg_lt  <= CPU_LOADTYPE'pos(executeLoadType);"
   print "   dbg_hw  <= hiloWait;"
   d = 1
   next
}
{ print }
