/*
 * Copyright (c) 2013-2014, ARM Limited and Contributors. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * Redistributions of source code must retain the above copyright notice, this
 * list of conditions and the following disclaimer.
 *
 * Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * Neither the name of ARM nor the names of its contributors may be used
 * to endorse or promote products derived from this software without specific
 * prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#include <arch.h>
#include <asm_macros.S>
#include <bl_common.h>
#include <gic_v2.h>
#include "../plat_def.h"
#include <pl011.h>
#include "../drivers/pwrc/plat_pwrc.h"

	.globl	platform_get_entrypoint
	.globl	plat_secondary_cold_boot_setup
	.globl	platform_mem_init
	.globl	plat_report_exception
	.globl	platform_is_primary_cpu
	.globl	plat_crash_console_init
	.globl	plat_crash_console_putc

	.macro	plat_choose_gicmmap  param1, param2, x_tmp, w_tmp, res
	ldr	\x_tmp, =VE_SYSREGS_BASE + V2M_SYS_ID
	ldr	\w_tmp, [\x_tmp]
	ubfx	\w_tmp, \w_tmp, #SYS_ID_BLD_SHIFT, #SYS_ID_BLD_LENGTH
	cmp	\w_tmp, #BLD_GIC_VE_MMAP
	csel	\res, \param1, \param2, eq
	.endm

	/* -----------------------------------------------------
	 * void plat_secondary_cold_boot_setup (void);
	 *
	 * This function performs any platform specific actions
	 * needed for a secondary cpu after a cold reset e.g
	 * mark the cpu's presence, mechanism to place it in a
	 * holding pen etc.
	 * TODO: Should we read the PSYS register to make sure
	 * that the request has gone through.
	 * -----------------------------------------------------
	 */
func plat_secondary_cold_boot_setup
	/* ---------------------------------------------
	 * Power down this cpu.
	 * TODO: Do we need to worry about powering the
	 * cluster down as well here. That will need
	 * locks which we won't have unless an elf-
	 * loader zeroes out the zi section.
	 * ---------------------------------------------
	 */
	mrs	x0, mpidr_el1
	ldr	x1, =PWRC_BASE
	str	w0, [x1, #PPOFFR_OFF]

	/* ---------------------------------------------
	 * Deactivate the gic cpu interface as well
	 * ---------------------------------------------
	 */
	ldr	x0, =VE_GICC_BASE
	ldr	x1, =BASE_GICC_BASE
	plat_choose_gicmmap	x0, x1, x2, w2, x1
	mov	w0, #(IRQ_BYP_DIS_GRP1 | FIQ_BYP_DIS_GRP1)
	orr	w0, w0, #(IRQ_BYP_DIS_GRP0 | FIQ_BYP_DIS_GRP0)
	str	w0, [x1, #GICC_CTLR]

	/* ---------------------------------------------
	 * There is no sane reason to come out of this
	 * wfi so panic if we do. This cpu will be pow-
	 * ered on and reset by the cpu_on pm api
	 * ---------------------------------------------
	 */
	dsb	sy
	wfi
cb_panic:
	b	cb_panic


	/* -----------------------------------------------------
	 * void platform_get_entrypoint (unsigned int mpid);
	 *
	 * Main job of this routine is to distinguish between
	 * a cold and warm boot.
	 * On a cold boot the secondaries first wait for the
	 * platform to be initialized after which they are
	 * hotplugged in. The primary proceeds to perform the
	 * platform initialization.
	 * On a warm boot, each cpu jumps to the address in its
	 * mailbox.
	 *
	 * TODO: Not a good idea to save lr in a temp reg
	 * TODO: PSYSR is a common register and should be
	 * 	accessed using locks. Since its not possible
	 * 	to use locks immediately after a cold reset
	 * 	we are relying on the fact that after a cold
	 * 	reset all cpus will read the same WK field
	 * -----------------------------------------------------
	 */

/*
func platform_get_entrypoint
	mov	x9, x30 // lr
	mov	x2, x0
	ldr	x1, =PWRC_BASE
	str	w2, [x1, #PSYSR_OFF]
	ldr	w2, [x1, #PSYSR_OFF]
	ubfx	w2, w2, #PSYSR_WK_SHIFT, #PSYSR_WK_MASK
	cmp	w2, #WKUP_PPONR
	beq	warm_reset
	cmp	w2, #WKUP_GICREQ
	beq	warm_reset
	mov	x0, #0
	b	exit
*/

func platform_get_entrypoint
	mov	x9, x30 // lr

	// Check first_boot flag
	// if first_boot flag is not 0, do cold boot initialization,
	// then set first_boot flag to 0
	// else, it's warm boot, jump via mailbox
	ldr		x1, =first_boot
	ldr		w2, [x1]
	cmp		w2, #0
	beq		warm_reset
	str		wzr, [x1]
	mov		x0,	#0
	b		exit

warm_reset:
	/* ---------------------------------------------
	 * A per-cpu mailbox is maintained in the tru-
	 * sted DRAM. Its flushed out of the caches
	 * after every update using normal memory so
	 * its safe to read it here with SO attributes
	 * ---------------------------------------------
	 */
	ldr	x10, =MBOX_BASE
	bl	platform_get_core_pos
	lsl	x0, x0, #CACHE_WRITEBACK_SHIFT
	ldr	x0, [x10, x0]
	cbz	x0, _panic
exit:
	ret	x9
_panic:	b	_panic


	/* -----------------------------------------------------
	 * void platform_mem_init (void);
	 *
	 * Zero out the mailbox registers in the shared memory.
	 * The mmu is turned off right now and only the primary can
	 * ever execute this code. Secondaries will read the
	 * mailboxes using SO accesses. In short, BL31 will
	 * update the mailboxes after mapping the tzdram as
	 * normal memory. It will flush its copy after update.
	 * BL1 will always read the mailboxes with the MMU off
	 * -----------------------------------------------------
	 */
func platform_mem_init
	ldr	x0, =MBOX_BASE
	mov	w1, #PLATFORM_CORE_COUNT
loop:
	str	xzr, [x0], #CACHE_WRITEBACK_GRANULE
	subs	w1, w1, #1
	b.gt	loop
	ret

	/* ---------------------------------------------
	 * void plat_report_exception(unsigned int type)
	 * Function to report an unhandled exception
	 * with platform-specific means.
	 * On FVP platform, it updates the LEDs
	 * to indicate where we are
	 * ---------------------------------------------
	 */
func plat_report_exception
	mrs	x1, CurrentEl
	lsr	x1, x1, #MODE_EL_SHIFT
	lsl	x1, x1, #SYS_LED_EL_SHIFT
	lsl	x0, x0, #SYS_LED_EC_SHIFT
	mov	x2, #(SECURE << SYS_LED_SS_SHIFT)
	orr	x0, x0, x2
	orr	x0, x0, x1
	mov	x1, #VE_SYSREGS_BASE
	add	x1, x1, #V2M_SYS_LED
	str	w0, [x1]
	ret

        .globl read_l2actlr
func read_l2actlr
        dsb sy
        MRS x0, S3_1_C15_C0_0     /* @Read L2ACTLR_EL1 into Rt */
        dsb sy
        isb
	ret

        .globl write_l2actlr
func write_l2actlr
        dsb sy
        MSR S3_1_C15_C0_0, x0     /* @write L2ACTLR_EL1 into Rt */
        isb
        dsb sy
	ret

        .globl read_l2ectlr
func read_l2ectlr
        MRS x0, S3_1_C11_C0_3     /* @Read L2ECTLR_EL1 into Rt */
        dsb sy
        isb
	ret

        .globl write_l2ectlr
func write_l2ectlr
        dsb sy
        MSR S3_1_C11_C0_3, x0     /* @write L2ECTLR_EL1 into Rt */
        isb
        dsb sy
	ret

        .globl read_cpuactlr
func read_cpuactlr
        dsb sy
        MRS x0, S3_1_C15_C2_0     /* @Read CPUACTLR_EL1 into Rt */
        dsb sy
        isb
	ret

        .globl write_cpuactlr
func write_cpuactlr
        dsb sy
        MSR S3_1_C15_C2_0, x0     /* @write CPUACTLR_EL1 into Rt */
        isb
        dsb sy
	ret

	.globl	read_cpuectlr
func read_cpuectlr
	MRS	x0, S3_1_C15_C2_1
	ret

	.globl	write_cpuectlr
func write_cpuectlr
	MSR	S3_1_C15_C2_1, x0
	ret


func platform_is_primary_cpu
	and	x0, x0, #(MPIDR_CLUSTER_MASK | MPIDR_CPU_MASK)
	cmp	x0, #FVP_PRIMARY_CPU
	cset	x0, eq
	ret

	/* Define a crash console for the plaform */
#define FVP_CRASH_CONSOLE_BASE		PL011_UART0_BASE

	/* ---------------------------------------------
	 * int plat_crash_console_init(void)
	 * Function to initialize the crash console
	 * without a C Runtime to print crash report.
	 * Clobber list : x0, x1, x2
	 * ---------------------------------------------
	 */
func plat_crash_console_init
	mov_imm	x0, FVP_CRASH_CONSOLE_BASE
	mov_imm	x1, PL011_UART0_CLK_IN_HZ
	mov_imm	x2, PL011_BAUDRATE
/*	b	console_core_init   */
	ret

	/* ---------------------------------------------
	 * int plat_crash_console_putc(int c)
	 * Function to print a character on the crash
	 * console without a C Runtime.
	 * Clobber list : x1, x2
	 * ---------------------------------------------
	 */
func plat_crash_console_putc
	b	mt_console_core_putc

	/* --------------------------------------------------------
	 * int mt_console_core_putc(int c, unsigned int base_addr)
	 * Function to output a character over the console. It
	 * returns the character printed on success or -1 on error.
	 * In : w0 - character to be printed
	 *      x1 - console base address
	 * Out : return -1 on error else return character.
	 * Clobber list : x0 x1 x2
	 * --------------------------------------------------------
	 */
func mt_console_core_putc
	/*
	 * Check teearg->atf_log_buf_size.
	   Exit if atf_log_buf_size equals 0
	 */
	adr	x2, ptr_atf_crash_flag
	ldr	x2, [x2]
	cbz x2, exit_putc	/* exit if ptr_atf_crash_flag equals NULL */

	/*
	 * set atf crash magic number
	 */
1:
	adr	x2, ptr_atf_crash_flag
	ldr	x2, [x2]
	mov_imm x1, 0xdead1abf
	str	w1, [x2]				/* p_atf_log_ctrl->atf_crash_flag = 0xdead1abf */

    ldr	w2, [x2]		/* can't use w3 return addr, w4, start of buffer addr */
	cmp	w2, w1
	b.ne	1b

	/*
	 * get cpu id
	 */
	mrs	x1, mpidr_el1
	and	x2, x1, #MPIDR_CPU_MASK			/* refer to platform_get_core_pos */
	and	x1, x1, #MPIDR_CLUSTER_MASK
	add	x1, x2, x1, LSR #6				/* x1 = cpu id (cpu id = aff0 + aff1*4 ) */

	adr	x2, ptr_atf_except_write_pos_per_cpu
	ldr	x2, [x2]
	add x2, x2, x1, LSL # 3
							/* plus (cpu_id * 8) --> &p_atf_log_ctrl->atf_except_write_pos_per_cpu[cpu_id]
										   x2 = &p_atf_log_ctrl->atf_except_write_pos_per_cpu[cpu_id];
										*/
	/* log write */
	ldr	x1, [x2]			/* w1 = p_atf_log_ctrl->atf_except_write_pos_per_cpu[cpu_id] */
	strb	w0, [x1]		/* *x1 = w0 --> *(p_atf_log_ctrl->atf_except_write_pos_per_cpu[cpu_id]) = c) */
	add	x1, x1, #1			/* w1++ */
	str	x1, [x2]			/* p_atf_log_ctrl->atf_except_write_pos_per_cpu[cpu_id] = w1 */
exit_putc:
	ret


	.data
first_boot:
	.long	0x1


