# Usage: quartus_sta -t report.tcl <revision>
# Writes the worst setup path per clock (Slow 1100mV 85C) to output_files_<rev>/worst_paths.txt.
set rev [lindex $quartus(args) 0]
project_open gte_slice -revision $rev
create_timing_netlist -model slow
read_sdc
set_operating_conditions [lindex [get_available_operating_conditions] 0]
update_timing_netlist
foreach_in_collection c [get_clocks] {
   set n [get_clock_info -name $c]
   report_timing -setup -npaths 1 -to_clock $n -detail full_path -file output_files_$rev/worst_$n.txt
}
project_close
