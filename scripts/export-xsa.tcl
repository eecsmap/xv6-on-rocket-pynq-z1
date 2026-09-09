# Export the hardware handoff the FSBL build needs.
#
#   cd pynqz1 && vivado -mode batch -source ../../scripts/export-xsa.tcl
#
# The .xsa also carries ps7_init.c/.h, which is the PS7 register initialisation
# sequence the FSBL links in. Regenerating it here is worth knowing about: on
# this design 2024.1 and 2025.2.1 produce byte-identical ps7_init sources, which
# is a stronger check that the board preset applied than reading properties back
# one at a time.
set proj [lindex [glob -nocomplain */*.xpr] 0]
if {$proj eq ""} { puts "export-xsa: no .xpr found; run from the board directory"; exit 1 }
open_project $proj
open_bd_design [get_files system.bd]
write_hw_platform -fixed -force -include_bit ./pynqz1_rocketchip_ZynqFPGAConfig.xsa
puts "export-xsa: wrote pynqz1_rocketchip_ZynqFPGAConfig.xsa"
exit
