# Timing paths of the SDRAM interface in every operating condition (docs/pocket/MEMTEST.md, Compile results).
#   cd pocket/memtest/fpga && quartus_sta -t ../tools/sta_report.tcl <revision>
# Writes output_files/<revision>.sdram_paths.rpt: the worst setup and hold path of the read capture
# (dram_dq pins to the clk_cap registers; excluded from the analysis, reported with -false_path for the static phase only),
# of the dq_cap3 -> dq_r transfer (clk_cap to the system clock, with the swing of the capture phase as uncertainty) and of
# the command / write data pins, per model, and output_files/<revision>.sys_paths.rpt: the worst system-clock setup
# paths of the slow models.
set rev [lindex $argv 0]
project_open ap_core -revision $rev
create_timing_netlist
read_sdc
update_timing_netlist

set out "output_files/$rev.sdram_paths.rpt"
file delete -force $out
foreach_in_collection op [get_available_operating_conditions] {
    set_operating_conditions $op
    update_timing_netlist
    set name [get_operating_conditions_info $op -display_name]
    foreach {tag args} [list \
        "read capture setup (excluded)" [list -false_path -setup -from [get_ports {dram_dq[*]}]] \
        "read capture hold (excluded)"  [list -false_path -hold  -from [get_ports {dram_dq[*]}]] \
        "capture to system setup" [list -setup -from_clock [get_clocks {*counter[2].output_counter*}] -to_clock [get_clocks {*counter[0].output_counter*}]] \
        "capture to system hold"  [list -hold  -from_clock [get_clocks {*counter[2].output_counter*}] -to_clock [get_clocks {*counter[0].output_counter*}]] \
        "command/data setup" [list -setup -to [get_ports {dram_dq[*] dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n}]] \
        "command/data hold"  [list -hold  -to [get_ports {dram_dq[*] dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n}]]] {
        set panel "$name: $tag"
        eval report_timing $args -npaths 1 -detail full_path -panel_name \"$panel\" -file $out -append
    }
}
# the 600 worst setup paths of the system clock in each slow model
set sysout "output_files/$rev.sys_paths.rpt"
file delete -force $sysout
foreach_in_collection op [get_available_operating_conditions] {
    set name [get_operating_conditions_info $op -display_name]
    if {[string match "Slow*" $name]} {
        set_operating_conditions $op
        update_timing_netlist
        report_timing -setup -npaths 600 -to_clock [get_clocks {*counter[0].output_counter*}] -detail summary \
            -panel_name "$name: sys clock worst setup" -file $sysout -append
        report_timing -setup -npaths 2 -to_clock [get_clocks {*counter[0].output_counter*}] -detail full_path \
            -panel_name "$name: sys clock worst setup, full" -file $sysout -append
    }
}
delete_timing_netlist
project_close
