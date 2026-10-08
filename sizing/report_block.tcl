# Usage: quartus_sta -t report_block.tcl <project> <revision>
# Writes output_files_<rev>/slack_summary.txt: worst setup and hold slack per clock in all four corners,
# plus the worst setup path per clock at the slow 85 C corner in worst_<clk>.txt. Fmax: the flow's <rev>.sta.rpt.
set proj [lindex $quartus(args) 0]
set rev  [lindex $quartus(args) 1]
project_open $proj -revision $rev
create_timing_netlist -model slow
read_sdc
set out [open output_files_$rev/slack_summary.txt w]
set first 1
foreach model {slow} {
   foreach oc [get_available_operating_conditions] {
      set_operating_conditions $oc
      update_timing_netlist
      foreach_in_collection c [get_clocks] {
         set n [get_clock_info -name $c]
         set su [get_timing_paths -setup -npaths 1 -to_clock $n]
         set ho [get_timing_paths -hold  -npaths 1 -to_clock $n]
         set s "n/a"; set h "n/a"
         foreach_in_collection p $su { set s [get_path_info $p -slack] }
         foreach_in_collection p $ho { set h [get_path_info $p -slack] }
         puts $out "$model | $oc | $n | setup $s | hold $h"
         if {$model eq "slow" && $first} {
            report_timing -setup -npaths 1 -to_clock $n -detail full_path -file output_files_$rev/worst_$n.txt
         }
      }
      set first 0
   }
}
close $out
project_close
