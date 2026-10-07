# Usage: quartus_sta -t report_gte.tcl <revision>
# Writes the 10 worst setup paths per clock (Slow 1100mV 85C) to output_files_<rev>/worst_<clk>.txt.
set rev [lindex $quartus(args) 0]
project_open gte_size -revision $rev
create_timing_netlist -model slow
read_sdc
update_timing_netlist
foreach_in_collection c [get_clocks] {
   set n [get_clock_info -name $c]
   report_timing -setup -npaths 10 -to_clock $n -detail summary -file output_files_$rev/worst_$n.txt
}
project_close
