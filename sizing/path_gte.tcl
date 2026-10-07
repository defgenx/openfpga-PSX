# Usage: quartus_sta -t path_gte.tcl <revision>: full detail of the worst clk2x setup path, slow 0C and 85C.
set rev [lindex $quartus(args) 0]
project_open gte_size -revision $rev
create_timing_netlist -model slow
read_sdc
foreach cond [get_available_operating_conditions] {
   if {[string match *slow* $cond]} {
      set_operating_conditions $cond
      update_timing_netlist
      report_timing -setup -npaths 1 -to_clock clk2x -detail full_path -file output_files_$rev/path_$cond.txt
   }
}
project_close
