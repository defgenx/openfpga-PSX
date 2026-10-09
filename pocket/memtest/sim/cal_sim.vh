// Simulation constants of the calibrated read capture (docs/pocket/MEMTEST.md, Calibration contract).
// SIM_PAD_NS delays the SDRAM model's read data so that its window, seen from the capture clock, is centred at
// about step MT_CAL_NOM of the swept range; SIM_SCAN_DIV is the system clock over the PLL's scan clock.
`ifdef SDRAM_135
  `define SIM_PAD_NS   2.05
  `define SIM_SCAN_DIV 4
`else
  `define SIM_PAD_NS   2.82
  `define SIM_SCAN_DIV 3
`endif
