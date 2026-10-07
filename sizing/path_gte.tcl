# Usage: quartus_sta -t path_gte.tcl <revision>
# Writes the full detail of the worst clk2x setup path for each slow corner to
# output_files_<rev>/path_slow_<T>C.txt.
set rev [lindex $quartus(args) 0]
project_open gte_size -revision $rev
create_timing_netlist
read_sdc
foreach_in_collection cond [get_available_operating_conditions] {
   if {[get_operating_conditions_info -model $cond] ne "slow"} { continue }
   set t [get_operating_conditions_info -temperature $cond]
   set_operating_conditions $cond
   update_timing_netlist
   report_timing -setup -npaths 1 -to_clock clk2x -detail full_path -file output_files_$rev/path_slow_${t}C.txt
}
project_close
