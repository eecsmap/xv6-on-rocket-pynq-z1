/*
 * Configuration for PYNQ-Z1 (Digilent/TUL, xc7z020clg400-1)
 * Adapted from zynq_zed.h: same XC7Z020 die, different package/board;
 * PYNQ-Z1's board files show UART0 (MIO 14..15) wired to the USB-UART
 * bridge, not UART1 as on Zedboard, and 512MB DDR3 (vs Zedboard's 256MB).
 * See zynq-common.h for Zynq common configs.
 *
 * SPDX-License-Identifier:	GPL-2.0+
 */

#ifndef __CONFIG_ZYNQ_PYNQZ1_H
#define __CONFIG_ZYNQ_PYNQZ1_H

#define CONFIG_SYS_SDRAM_SIZE		(512 * 1024 * 1024)

/* PYNQ-Z1's PS reference oscillator is 50MHz (PCW_CRYSTAL_PERIPHERAL_FREQMHZ
 * in the board preset), not the 33.33MHz Zedboard/ZC702 default clk.c
 * assumes. Every derived clock rate (including UART baud divisors) is
 * computed in software from this constant, so leaving it at the default
 * silently miscalculates all clock rates even though the PLLs themselves
 * are configured correctly by ps7_init(). */
#define CONFIG_ZYNQ_PS_CLK_FREQ		50000000UL

#define CONFIG_ZYNQ_SERIAL_UART0
#define CONFIG_ZYNQ_GEM0
#define CONFIG_ZYNQ_GEM_PHY_ADDR0	0

#define CONFIG_SYS_NO_FLASH

#define CONFIG_ZYNQ_USB
#define CONFIG_ZYNQ_SDHCI0
#define CONFIG_ZYNQ_QSPI

#define CONFIG_ZYNQ_BOOT_FREEBSD
#define CONFIG_DEFAULT_DEVICE_TREE	zynq-zed

#include <configs/zynq-common.h>

#endif /* __CONFIG_ZYNQ_PYNQZ1_H */
