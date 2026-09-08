# Verify the Digilent board preset actually reached the PS7.
#
#   vivado -mode batch -source check_ps7.tcl
#
# Run this after creating the project and before trusting a bitstream. It exists
# because pynqz1_bd.tcl sets exactly one CONFIG.PCW_* property by hand
# (PCW_USE_S_AXI_HP0); every other PS7 setting arrives through
#
#   apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
#       -config {apply_board_preset "1"}
#
# With the board file missing, set_property board_part fails, that automation
# applies nothing, and the PS7 falls back to defaults carrying Zedboard's
# 33.333 MHz reference clock. Synthesis, routing and write_bitstream all still
# succeed. The only symptom is an unreadable console on real hardware -- which
# is bug #2/#3 in the README, reintroduced, at the point where it is hardest to
# recognise as a configuration problem.
set proj [lindex [glob -nocomplain */*.xpr] 0]
if {$proj eq ""} { puts "check_ps7: no .xpr found; run from the board directory"; exit 1 }
open_project $proj
open_bd_design [get_files system.bd]
set ps [get_bd_cells -quiet processing_system7_0]
if {$ps eq ""} { puts "check_ps7: FAIL - no processing_system7_0 cell"; exit 1 }

# Expected values come from the Digilent PYNQ-Z1 preset, not from this design.
set expect {
  PCW_CRYSTAL_PERIPHERAL_FREQMHZ 50
  PCW_UART0_UART0_IO             {MIO 14 .. 15}
  PCW_UART0_PERIPHERAL_ENABLE    1
  PCW_APU_PERIPHERAL_FREQMHZ     650
  PCW_USE_S_AXI_HP0              1
}
set bad 0
foreach {p want} $expect {
  set got [get_property -quiet CONFIG.$p $ps]
  if {$got eq $want} {
    puts [format "  ok   %-32s = %s" $p $got]
  } else {
    puts [format "  FAIL %-32s = %s   (expected %s)" $p $got $want]
    incr bad
  }
}
if {$bad} {
  puts "check_ps7: FAIL - the board preset did not apply."
  puts "  Point Vivado at the Digilent board files and recreate the project:"
  puts "    set_param board.repoPaths \[list /path/to/vivado-boards/new/board_files\]"
  exit 1
}
puts "check_ps7: PASS - Digilent PYNQ-Z1 preset applied"
exit 0
