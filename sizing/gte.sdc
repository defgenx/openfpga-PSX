# Related, edge-aligned PLL clocks; paths between them are analysed, not cut.
# Override the port lists before sourcing: set gte_clk1x_ports {...} etc.
foreach v {gte_clk1x_ports gte_clk2x_ports gte_clk4x_ports} {
   if {![info exists $v]} { set $v "" }
}
if {$gte_clk1x_ports eq ""} { set gte_clk1x_ports clk1x }
if {$gte_clk2x_ports eq ""} { set gte_clk2x_ports clk2x }
if {$gte_clk4x_ports eq ""} { set gte_clk4x_ports clk4x }

# Create each clock only on ports that exist in the design.
proc gte_make_clock {name period ports} {
   set p [get_ports -nowarn $ports]
   if {[get_collection_size $p] > 0} { create_clock -name $name -period $period $p }
}
gte_make_clock clk1x 29.525 $gte_clk1x_ports   ;# 33.8688 MHz
gte_make_clock clk2x 14.762 $gte_clk2x_ports   ;# 67.7376 MHz
gte_make_clock clk4x 7.381  $gte_clk4x_ports   ;# 135.4752 MHz

derive_clock_uncertainty
