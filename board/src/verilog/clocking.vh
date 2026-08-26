/*

Rocket Chip Clock Configuration


Rocket Chip             1000              RC_CLK_MULT
 Clockrate     =   ---------------   X   -------------
  (in MHz)         ZYNQ_CLK_PERIOD       RC_CLK_DIVIDE


This sets the parameters used by rocketchip_wrapper.v to
generate its own clock.

Most uses should only change RC_CLK_MULT & RC_CLK_DIVIDE.
ZYNQ_CLK_PERIOD should only be changed to match the input
clock period set in the Vivado GUI and 
hw/src/constrs/pin_constraints.xdc

*/


`ifndef _clocking_vh_
`define _clocking_vh_


`define ZYNQ_CLK_PERIOD 8.0

`define RC_CLK_MULT     8.0

// 25.0 -> 40 MHz.  Upstream fpga-zynq ships 40.0, i.e. 25 MHz, which left a
// great deal on the table: at that constraint the routed design reported
// WNS = +16.1 ns on a 40 ns period, so the critical path was only 23.9 ns.
//
// 40 MHz closes with WNS = +3.395 ns, and at that setting the full 64-test
// usertests suite passes on hardware in 1482 s.
//
// 50 MHz (RC_CLK_DIVIDE 20.0) also closes, but only at WNS = +0.249 ns.  It
// booted and passed three individual usertests cases; a full-suite run was
// not completed, so its stability is UNVERIFIED.  A quarter of a nanosecond
// is inside the noise of on-chip variation and temperature drift, so it is
// not shipped.  Try it if you like, but re-verify on your own board.
//
// Note this clock also feeds the AXI interconnect and the PS's S_AXI_HP0
// port -- rocketchip_wrapper.v drives the block design's ext_clk_in from the
// MMCM output -- so raising it speeds up the memory path too, not just the
// core.  That is why the speedup tracks the clock ratio almost exactly
// (1.54x measured for a 1.6x clock) even on memory-heavy workloads.
`define RC_CLK_DIVIDE   25.0


`endif // _clocking_vh_
