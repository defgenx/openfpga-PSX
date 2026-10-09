# Worst system-clock setup paths of the slow models (docs/pocket/POCKET_TOP.md, "Shell skeleton").
#   cd pocket/psx/fpga && quartus_sta -t ../tools/sta_report.tcl <revision>
# Writes output_files/<revision>.sys_paths.rpt.
set rev [lindex $argv 0]
project_open ap_core -revision $rev
create_timing_netlist
read_sdc
update_timing_netlist

set out "output_files/$rev.sys_paths.rpt"
file delete -force $out
foreach_in_collection op [get_available_operating_conditions] {
    set_operating_conditions $op
    update_timing_netlist
    set name [get_operating_conditions_info $op -display_name]
    report_timing -setup -to_clock [get_clocks {*counter[0].output_counter*}] -npaths 3 -detail full_path -panel_name "$name: system clock setup" -file $out -append
}
