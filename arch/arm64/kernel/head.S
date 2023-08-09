/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Low-level CPU initialisation
 * Based on arch/arm/kernel/head.S
 *
 * Copyright (C) 1994-2002 Russell King
 * Copyright (C) 2003-2012 ARM Ltd.
 * Authors:	Catalin Marinas <catalin.marinas@arm.com>
 *		Will Deacon <will.deacon@arm.com>
 */

#include <linux/linkage.h>
#include <linux/init.h>
#include <linux/pgtable.h>

#include <asm/asm_pointer_auth.h>
#include <asm/assembler.h>
#include <asm/boot.h>
#include <asm/bug.h>
#include <asm/ptrace.h>
#include <asm/asm-offsets.h>
#include <asm/cache.h>
#include <asm/cputype.h>
#include <asm/el2_setup.h>
#include <asm/elf.h>
#include <asm/image.h>
#include <asm/kernel-pgtable.h>
#include <asm/kvm_arm.h>
#include <asm/memory.h>
#include <asm/pgtable-hwdef.h>
#include <asm/page.h>
#include <asm/scs.h>
#include <asm/smp.h>
#include <asm/sysreg.h>
#include <asm/thread_info.h>
#include <asm/virt.h>

#include "efi-header.S"

#if (PAGE_OFFSET & 0x1fffff) != 0
#error PAGE_OFFSET must be at least 2MB aligned
#endif

/*
 * Kernel startup entry point.
 * ---------------------------
 *
 * The requirements are:
 *   MMU = off, D-cache = off, I-cache = on or off,
 *   x0 = physical address to the FDT blob. x0 指向设备树地址
 *
 * Note that the callee-saved registers are used for storing variables
 * that are useful before the MMU is enabled. The allocations are described
 * in the entry routines.
 */
 /**
 为什么跳转到内核时指令高速缓存可以打开，数据高速缓存必须关闭？
 首先L1 icache是无法关闭的，其次dcache依赖mmu，mmu关闭，dcache无法使用。mmu关闭，所有内存默认non-cacheable
 **/
	__HEAD	// .section	".head.text","ax" 指定section
	/*
	 * DO NOT MODIFY. Image header expected by Linux boot-loaders.
	 */
	 /**
	 efi_signature_nop 其作用是在 EFI 签名列表中添加一个空占位符项
	 **/
	efi_signature_nop			// special NOP to identity as PE/COFF executable
	// 内核启动初始入口
	// b 指令使用label，是相对地址，使用寄存器是绝对地址跳转
	b	primary_entry			// branch to kernel start, magic
	.quad	0				// Image load offset from start of RAM, little-endian
	le64sym	_kernel_size_le			// Effective size of kernel image, little-endian
	le64sym	_kernel_flags_le		// Informative flags, little-endian
	.quad	0				// reserved
	.quad	0				// reserved
	.quad	0				// reserved
	.ascii	ARM64_IMAGE_MAGIC		// Magic number
	.long	.Lpe_header_offset		// Offset to the PE header.

	__EFI_PE_HEADER

	.section ".idmap.text","a"

	/*
	 * The following callee saved general purpose registers are used on the
	 * primary lowlevel boot path:
	 *
	 *  Register   Scope                      Purpose
	 *  x19        primary_entry() .. start_kernel()        whether we entered with the MMU on
	 *  x20        primary_entry() .. __primary_switch()    CPU boot mode
	 *  x21        primary_entry() .. start_kernel()        FDT pointer passed at boot in x0
	 *  x22        create_idmap() .. start_kernel()         ID map VA of the DT blob
	 *  x23        primary_entry() .. start_kernel()        physical misalignment/KASLR offset
	 *  x24        __primary_switch()                       linear map KASLR seed
	 *  x25        primary_entry() .. start_kernel()        supported VA size
	 *  x28        create_idmap()                           callee preserved temp register
	 */
SYM_CODE_START(primary_entry)
	bl	record_mmu_state	// 从系统控制寄存器提取mmu开启关闭状态放入x19
	bl	preserve_boot_args	// 把BootLoader传递的x0-x3寄存器放入boot_args数组
	bl	create_idmap		// 创建虚地址到物理地址的一一映射，开启MMU要用到

	/*
	 * If we entered with the MMU and caches on, clean the ID mapped part
	 * of the primary boot code to the PoC so we can safely execute it with
	 * the MMU off.
	 */
	 // 正常情况MMU是关闭的，所以会跳转到标签 0
	cbz	x19, 0f
	adrp	x0, __idmap_text_start
	adr_l	x1, __idmap_text_end
	adr_l	x2, dcache_clean_poc
	blr	x2
0:	mov	x0, x19	// mmu 状态放 x0
	bl	init_kernel_el			// w0=cpu_boot_mode
	mov	x20, x0					// 把x0 中的CPU boot mode备份到x20

	/*
	 * The following calls CPU setup code, see arch/arm64/mm/proc.S for
	 * details.
	 * On return, the CPU will be ready for the MMU to be turned on and
	 * the TCR will have been set.
	 */
#if VA_BITS > 48
	mrs_s	x0, SYS_ID_AA64MMFR2_EL1				// 取出arm64内存管理特性寄存器内容
	tst	x0, #0xf << ID_AA64MMFR2_EL1_VARange_SHIFT	// va range == 0, 48位虚地址，va range == 1 && 粒度64KB, 52位虚地址
	mov	x0, #VA_BITS
	mov	x25, #VA_BITS_MIN
	csel	x25, x25, x0, eq						// va bit <= 48 位
	mov	x0, x25
#endif
	bl	__cpu_setup			// initialise processor, x0存放的系统控制寄存器内容, mmu on, 下面开启mmu会读x0并写到系统控制寄存器
	b	__primary_switch
SYM_CODE_END(primary_entry)

	__INIT
SYM_CODE_START_LOCAL(record_mmu_state)
	mrs	x19, CurrentEL	// 获取当前运行级别
	cmp	x19, #CurrentEL_EL2	// 和EL2级别比较
	mrs	x19, sctlr_el1	// 获取 el1 系统控制寄存器内容
	b.ne	0f		// 如果当前不是EL2，跳转到label 0
	mrs	x19, sctlr_el2	// 当前是 el2, 获取el2 系统控制寄存器内容
0:
CPU_LE( tbnz	x19, #SCTLR_ELx_EE_SHIFT, 1f	) // 该bit为0是小端，为1是大端，所以用了两个test bit指令分别判断0和1，cpu实际大小端和宏定义的不一致，需要校正
CPU_BE( tbz	x19, #SCTLR_ELx_EE_SHIFT, 1f	)
	tst	x19, #SCTLR_ELx_C		// Z := (C == 0), C为i cache和d cache开关，1 - enable， 0 - disable
	and	x19, x19, #SCTLR_ELx_M		// isolate M bit，提取mmu状态
	csel	x19, xzr, x19, eq		// clear x19 if Z
	ret

	/*
	 * Set the correct endianness early so all memory accesses issued
	 * before init_kernel_el() occur in the correct byte order. Note that
	 * this means the MMU must be disabled, or the active ID map will end
	 * up getting interpreted with the wrong byte order.
	 */
	 // 代码定义的大小端和cpu寄存器读出来的大小端不一致，需要校正
1:	eor	x19, x19, #SCTLR_ELx_EE	// x19中大小端bit翻转
	bic	x19, x19, #SCTLR_ELx_M	// x19中mmu比特位关闭， 大小端对应bit发生翻转
	b.ne	2f	// 大端跳转label 2
	pre_disable_mmu_workaround	// 普通cpu为空
	msr	sctlr_el2, x19
	b	3f
	pre_disable_mmu_workaround
2:	msr	sctlr_el1, x19	// 改成小端，mmu关闭
3:	isb
	mov	x19, xzr
	ret
SYM_CODE_END(record_mmu_state)

/*
 * Preserve the arguments passed by the bootloader in x0 .. x3
 保存BootLoader传递的参数
 */
SYM_CODE_START_LOCAL(preserve_boot_args)
	mov	x21, x0				// x21=FDT

	// 获取boot_args地址，这个变量数组在setup.c中，用于保存x0 .. x3
	adr_l	x0, boot_args			// record the contents of
	stp	x21, x1, [x0]			// x0 .. x3 at kernel entry
	stp	x2, x3, [x0, #16]

	cbnz	x19, 0f				// skip cache invalidation if MMU is on
	dmb	sy				// needed before dc ivac with
						// MMU off

	add	x1, x0, #0x20			// 4 x 8 bytes
	// clean & invalidate boot_args数据
	b	dcache_inval_poc		// tail call
0:	str_l   x19, mmu_enabled_at_boot, x0	// mmu状态存储到这个变量，后续会用到
	ret
SYM_CODE_END(preserve_boot_args)

// 清掉内核页表
SYM_FUNC_START_LOCAL(clear_page_tables)
	/*
	 * Clear the init page tables.
	 */
	adrp	x0, init_pg_dir
	adrp	x1, init_pg_end
	sub	x2, x1, x0
	mov	x1, xzr
	b	__pi_memset			// tail call
SYM_FUNC_END(clear_page_tables)

/*
 * Macro to populate page table entries, these entries can be pointers to the next level
 * or last level entries pointing to physical memory.
 *
 *	tbl:	page table address
 *	rtbl:	pointer to page table or physical memory
 *	index:	start index to write
 *	eindex:	end index to write - [index, eindex] written to
 *	flags:	flags for pagetable entry to or in
 *	inc:	increment to rtbl between each entry
 *	tmp1:	temporary variable
 *
 * Preserves:	tbl, eindex, flags, inc
 * Corrupts:	index, tmp1
 * Returns:	rtbl
 */
	.macro populate_entries, tbl, rtbl, index, eindex, flags, inc, tmp1
.Lpe\@:	phys_to_pte \tmp1, \rtbl
	orr	\tmp1, \tmp1, \flags	// tmp1 = table entry
	str	\tmp1, [\tbl, \index, lsl #3]	// 写entry到页表， index << 3为页表内的偏移
	add	\rtbl, \rtbl, \inc	// rtbl = pa next level
	add	\index, \index, #1	// index++
	cmp	\index, \eindex		// index == eindex 填充结束
	b.ls	.Lpe\@
	.endm

/*
 * Compute indices of table entries from virtual address range. If multiple entries
 * were needed in the previous page table level then the next page table level is assumed
 * to be composed of multiple pages. (This effectively scales the end index).
 *
 *	vstart:	virtual address of start of range
 *	vend:	virtual address of end of range - we map [vstart, vend]
 *	shift:	shift used to transform virtual address into index
 *	order:  #imm 2log(number of entries in page table)
 *	istart:	index in table corresponding to vstart
 *	iend:	index in table corresponding to vend
 *	count:	On entry: how many extra entries were required in previous level, scales
 *			  our end index.
 *		On exit: returns how many extra entries required for next page table level
 *
 * Preserves:	vstart, vend
 * Returns:	istart, iend, count
 */
	.macro compute_indices, vstart, vend, shift, order, istart, iend, count
	ubfx	\istart, \vstart, \shift, \order	// 提取起始页目录索引
	ubfx	\iend, \vend, \shift, \order		// 提取结束页目录索引
	add	\iend, \iend, \count, lsl \order
	sub	\count, \iend, \istart			// 计算entry数量
	.endm

/*
 * Map memory for specified virtual address range. Each level of page table needed supports
 * multiple entries. If a level requires n entries the next page table level is assumed to be
 * formed from n pages.
 *
 *	tbl:	location of page table
 *	rtbl:	address to be used for first level page table entry (typically tbl + PAGE_SIZE)
 *	vstart:	virtual address of start of range
 *	vend:	virtual address of end of range - we map [vstart, vend - 1]
 *	flags:	flags to use to map last level entries
 *	phys:	physical address corresponding to vstart - physical memory is contiguous
 *	order:  #imm 2log(number of entries in PGD table)
 *
 * If extra_shift is set, an extra level will be populated if the end address does
 * not fit in 'extra_shift' bits. This assumes vend is in the TTBR0 range.
 *
 * Temporaries:	istart, iend, tmp, count, sv - these need to be different registers
 * Preserves:	vstart, flags
 * Corrupts:	tbl, rtbl, vend, istart, iend, tmp, count, sv
 */
	.macro map_memory, tbl, rtbl, vstart, vend, flags, phys, order, istart, iend, tmp, count, sv, extra_shift
	sub \vend, \vend, #1
	add \rtbl, \tbl, #PAGE_SIZE	// l1 页表entry,用于填充l0表项
	mov \count, #0

	.ifnb	\extra_shift
	tst	\vend, #~((1 << (\extra_shift)) - 1)
	b.eq	.L_\@
	compute_indices \vstart, \vend, #\extra_shift, #(PAGE_SHIFT - 3), \istart, \iend, \count
	mov \sv, \rtbl
	populate_entries \tbl, \rtbl, \istart, \iend, #PMD_TYPE_TABLE, #PAGE_SIZE, \tmp
	mov \tbl, \sv
	.endif
.L_\@:
	// 计算指定虚地址起止索引和数量
	compute_indices \vstart, \vend, #PGDIR_SHIFT, #\order, \istart, \iend, \count
	mov \sv, \rtbl
	// 填充l0页表项
	populate_entries \tbl, \rtbl, \istart, \iend, #PMD_TYPE_TABLE, #PAGE_SIZE, \tmp
	mov \tbl, \sv

#if SWAPPER_PGTABLE_LEVELS > 3
	// 填充l1
	compute_indices \vstart, \vend, #PUD_SHIFT, #(PAGE_SHIFT - 3), \istart, \iend, \count
	mov \sv, \rtbl
	populate_entries \tbl, \rtbl, \istart, \iend, #PMD_TYPE_TABLE, #PAGE_SIZE, \tmp
	mov \tbl, \sv
#endif

#if SWAPPER_PGTABLE_LEVELS > 2
	// 填充l2
	compute_indices \vstart, \vend, #SWAPPER_TABLE_SHIFT, #(PAGE_SHIFT - 3), \istart, \iend, \count
	mov \sv, \rtbl
	populate_entries \tbl, \rtbl, \istart, \iend, #PMD_TYPE_TABLE, #PAGE_SIZE, \tmp
	mov \tbl, \sv
#endif
	// 填充l3
	compute_indices \vstart, \vend, #SWAPPER_BLOCK_SHIFT, #(PAGE_SHIFT - 3), \istart, \iend, \count
	bic \rtbl, \phys, #SWAPPER_BLOCK_SIZE - 1
	populate_entries \tbl, \rtbl, \istart, \iend, \flags, #SWAPPER_BLOCK_SIZE, \tmp
	.endm

/*
 * Remap a subregion created with the map_memory macro with modified attributes
 * or output address. The entire remapped region must have been covered in the
 * invocation of map_memory.
 *
 * x0: last level table address (returned in first argument to map_memory)
 * x1: start VA of the existing mapping
 * x2: start VA of the region to update
 * x3: end VA of the region to update (exclusive)
 * x4: start PA associated with the region to update
 * x5: attributes to set on the updated region
 * x6: order of the last level mappings
 */
SYM_FUNC_START_LOCAL(remap_region)
	sub	x3, x3, #1		// make end inclusive

	// Get the index offset for the start of the last level table
	lsr	x1, x1, x6
	bfi	x1, xzr, #0, #PAGE_SHIFT - 3

	// Derive the start and end indexes into the last level table
	// associated with the provided region
	lsr	x2, x2, x6
	lsr	x3, x3, x6
	sub	x2, x2, x1
	sub	x3, x3, x1

	mov	x1, #1
	lsl	x6, x1, x6		// block size at this level

	// 填充最后一级页表
	populate_entries x0, x4, x2, x3, x5, x6, x7
	ret
SYM_FUNC_END(remap_region)

SYM_FUNC_START_LOCAL(create_idmap)
	mov	x28, lr
	/*
	 * The ID map carries a 1:1 mapping of the physical address range
	 * covered by the loaded image, which could be anywhere in DRAM. This
	 * means that the required size of the VA (== PA) space is decided at
	 * boot time, and could be more than the configured size of the VA
	 * space for ordinary kernel and user space mappings.
	 *
	 * There are three cases to consider here:
	 * - 39 <= VA_BITS < 48, and the ID map needs up to 48 VA bits to cover
	 *   the placement of the image. In this case, we configure one extra
	 *   level of translation on the fly for the ID map only. (This case
	 *   also covers 42-bit VA/52-bit PA on 64k pages).
	 *
	 * - VA_BITS == 48, and the ID map needs more than 48 VA bits. This can
	 *   only happen when using 64k pages, in which case we need to extend
	 *   the root level table rather than add a level. Note that we can
	 *   treat this case as 'always extended' as long as we take care not
	 *   to program an unsupported T0SZ value into the TCR register.
	 *
	 * - Combinations that would require two additional levels of
	 *   translation are not supported, e.g., VA_BITS==36 on 16k pages, or
	 *   VA_BITS==39/4k pages with 5-level paging, where the input address
	 *   requires more than 47 or 48 bits, respectively.
	 */
#if (VA_BITS < 48)
#define IDMAP_PGD_ORDER	(VA_BITS - PGDIR_SHIFT)
#define EXTRA_SHIFT	(PGDIR_SHIFT + PAGE_SHIFT - 3)

	/*
	 * If VA_BITS < 48, we have to configure an additional table level.
	 * First, we have to verify our assumption that the current value of
	 * VA_BITS was chosen such that all translation levels are fully
	 * utilised, and that lowering T0SZ will always result in an additional
	 * translation level to be configured.
	 */
#if VA_BITS != EXTRA_SHIFT
#error "Mismatch between VA_BITS and page size/number of translation levels"
#endif
#else
#define IDMAP_PGD_ORDER	(PHYS_MASK_SHIFT - PGDIR_SHIFT)
#define EXTRA_SHIFT
	/*
	 * If VA_BITS == 48, we don't have to configure an additional
	 * translation level, but the top-level table has more entries.
	 */
#endif
	adrp	x0, init_idmap_pg_dir	// 在vmlinux.lds.S中定义
	adrp	x3, _text
	adrp	x6, _end + MAX_FDT_SIZE + SWAPPER_BLOCK_SIZE
	mov	x7, SWAPPER_RX_MMUFLAGS

	// 创建映射表
	map_memory x0, x1, x3, x6, x7, x3, IDMAP_PGD_ORDER, x10, x11, x12, x13, x14, EXTRA_SHIFT

	/* Remap the kernel page tables r/w in the ID map */
	adrp	x1, _text
	adrp	x2, init_pg_dir
	adrp	x3, init_pg_end
	bic	x4, x2, #SWAPPER_BLOCK_SIZE - 1
	mov	x5, SWAPPER_RW_MMUFLAGS
	mov	x6, #SWAPPER_BLOCK_SHIFT
	bl	remap_region

	/* Remap the FDT after the kernel image */
	adrp	x1, _text
	adrp	x22, _end + SWAPPER_BLOCK_SIZE
	bic	x2, x22, #SWAPPER_BLOCK_SIZE - 1
	bfi	x22, x21, #0, #SWAPPER_BLOCK_SHIFT		// remapped FDT address
	add	x3, x2, #MAX_FDT_SIZE + SWAPPER_BLOCK_SIZE
	bic	x4, x21, #SWAPPER_BLOCK_SIZE - 1
	mov	x5, SWAPPER_RW_MMUFLAGS
	mov	x6, #SWAPPER_BLOCK_SHIFT
	bl	remap_region

	/*
	 * Since the page tables have been populated with non-cacheable
	 * accesses (MMU disabled), invalidate those tables again to
	 * remove any speculatively loaded cache lines.
	 */
	cbnz	x19, 0f				// skip cache invalidation if MMU is on
	dmb	sy	// 系统级屏障

	// clean & invalidate 全局identity mapping页表，flush动作，清L1 dcache
	adrp	x0, init_idmap_pg_dir
	adrp	x1, init_idmap_pg_end
	bl	dcache_inval_poc	// clean & invalidate dcache
0:	ret	x28
SYM_FUNC_END(create_idmap)

// 根据新的内核虚地址创建页表
SYM_FUNC_START_LOCAL(create_kernel_mapping)
	adrp	x0, init_pg_dir
	mov_q	x5, KIMAGE_VADDR		// compile time __va(_text)
#ifdef CONFIG_RELOCATABLE
	add	x5, x5, x23			// add KASLR displacement，x23保存内核地址随机化offset，重新映射kernel地址需要把这个offset加上
#endif
	adrp	x6, _end			// runtime __pa(_end)
	adrp	x3, _text			// runtime __pa(_text)
	sub	x6, x6, x3			// _end - _text
	add	x6, x6, x5			// runtime __va(_end)
	mov	x7, SWAPPER_RW_MMUFLAGS

	map_memory x0, x1, x5, x6, x7, x3, (VA_BITS - PGDIR_SHIFT), x10, x11, x12, x13, x14

	dsb	ishst				// sync with page table walker
	ret
SYM_FUNC_END(create_kernel_mapping)

	/*
	 * Initialize CPU registers with task-specific and cpu-specific context.
	 *
	 * Create a final frame record at task_pt_regs(current)->stackframe, so
	 * that the unwinder can identify the final frame record of any task by
	 * its location in the task stack. We reserve the entire pt_regs space
	 * for consistency with user tasks and kthreads.
	 */
	.macro	init_cpu_task tsk, tmp1, tmp2
	msr	sp_el0, \tsk	// task地址备份到sp_el0

	// 初始化sp寄存器, 栈从高地址向低地址增长
	ldr	\tmp1, [\tsk, #TSK_STACK]
	add	sp, \tmp1, #THREAD_SIZE	// sp指向栈底
	sub	sp, sp, #PT_REGS_SIZE	// stack保留备份寄存器空间

	stp	xzr, xzr, [sp, #S_STACKFRAME]	// 清空 stackframe字段
	add	x29, sp, #S_STACKFRAME			// 设置x29  FP指向stackframe

	// 设置影子调用栈,备份返回地址, 返回时做检查
	scs_load_current

	adr_l	\tmp1, __per_cpu_offset
	ldr	w\tmp2, [\tsk, #TSK_TI_CPU]
	ldr	\tmp1, [\tmp1, \tmp2, lsl #3]
	set_this_cpu_offset \tmp1	// tpidr_el1, per-cpu实现寄存器
	.endm

/*
 * The following fragment of code is executed with the MMU enabled.
 *
 *   x0 = __pa(KERNEL_START)
 */
SYM_FUNC_START_LOCAL(__primary_switched)
	adr_l	x4, init_task		// struct task_struct init_task
	init_cpu_task x4, x5, x6	// 初始化task结构体

	// 设置el1 中断向量寄存器, 中断向量位于entry.S
	adr_l	x8, vectors			// load VBAR_EL1 with virtual
	msr	vbar_el1, x8			// vector table address
	isb

	stp	x29, x30, [sp, #-16]!
	mov	x29, sp

	// 设备树地址放x21
	str_l	x21, __fdt_pointer, x5		// Save FDT pointer

	// 内核镜像虚地址放x4, _text
	ldr_l	x4, kimage_vaddr		// Save the offset between
	sub	x4, x4, x0			// the kernel virtual and
	str_l	x4, kimage_voffset, x5		// physical mappings

	mov	x0, x20
	bl	set_cpu_boot_mode_flag		// cpu boot mode保存到全局变量

	// Clear BSS
	adr_l	x0, __bss_start
	mov	x1, xzr
	adr_l	x2, __bss_stop
	sub	x2, x2, x0
	bl	__pi_memset
	dsb	ishst				// Make zero page visible to PTW

#if VA_BITS > 48
	adr_l	x8, vabits_actual		// Set this early so KASAN early init
	str	x25, [x8]			// ... observes the correct value
	dc	civac, x8			// Make visible to booting secondaries
#endif

#ifdef CONFIG_RANDOMIZE_BASE
	adrp	x5, memstart_offset_seed	// Save KASLR linear map seed
	strh	w24, [x5, :lo12:memstart_offset_seed]
#endif
#if defined(CONFIG_KASAN_GENERIC) || defined(CONFIG_KASAN_SW_TAGS)
	bl	kasan_early_init
#endif
	mov	x0, x21				// pass FDT address in x0
	bl	early_fdt_map			// Try mapping the FDT early
	mov	x0, x20				// pass the full boot status
	bl	init_feature_override		// Parse cpu feature overrides
#ifdef CONFIG_UNWIND_PATCH_PAC_INTO_SCS
	bl	scs_patch_vmlinux
#endif
	mov	x0, x20
	bl	finalise_el2			// Prefer VHE if possible
	ldp	x29, x30, [sp], #16
	bl	start_kernel			// 正式进入内核代码
	ASM_BUG()
SYM_FUNC_END(__primary_switched)

/*
 * end early head section, begin head code that is also used for
 * hotplug and needs to have the same protections as the text region
 */
	.section ".idmap.text","a"

/*
 * Starting from EL2 or EL1, configure the CPU to execute at the highest
 * reachable EL supported by the kernel in a chosen default state. If dropping
 * from EL2 to EL1, configure EL2 before configuring EL1.
 *
 * Since we cannot always rely on ERET synchronizing writes to sysregs (e.g. if
 * SCTLR_ELx.EOS is clear), we place an ISB prior to ERET.
 *
 * Returns either BOOT_CPU_MODE_EL1 or BOOT_CPU_MODE_EL2 in x0 if
 * booted in EL1 or EL2 respectively, with the top 32 bits containing
 * potential context flags. These flags are *not* stored in __boot_cpu_mode.
 *
 * x0: whether we are being called from the primary boot path with the MMU on
 */
SYM_FUNC_START(init_kernel_el)
	mrs	x1, CurrentEL
	cmp	x1, #CurrentEL_EL2
	b.eq	init_el2	// 当前是EL2, 跳转到el2初始化代码

SYM_INNER_LABEL(init_el1, SYM_L_LOCAL)
	mov_q	x0, INIT_SCTLR_EL1_MMU_OFF	// 设置mmu off条件下寄存器初始值
	pre_disable_mmu_workaround
	msr	sctlr_el1, x0					// 把上面的值写入系统控制寄存器
	isb									// 指令屏障，重新取指
	mov_q	x0, INIT_PSTATE_EL1			// 把el1初始pstate值放入x0
	msr	spsr_el1, x0					// 设置el1 pstate寄存器
	msr	elr_el1, lr						// 设置el1 异常返回地址为 lr
	mov	w0, #BOOT_CPU_MODE_EL1			// 设置boot CPU mode
	eret

SYM_INNER_LABEL(init_el2, SYM_L_LOCAL)
	msr	elr_el2, lr						// 备份lr寄存器

	// clean all HYP code to the PoC if we booted at EL2 with the MMU on
	cbz	x0, 0f
	adrp	x0, __hyp_idmap_text_start
	adr_l	x1, __hyp_text_end
	adr_l	x2, dcache_clean_poc
	blr	x2
0:
	mov_q	x0, HCR_HOST_NVHE_FLAGS
	msr	hcr_el2, x0						// 初始化虚拟化控制寄存器
	isb

	init_el2_state						// 初始化el2 寄存器

	/* Hypervisor stub */
	adr_l	x0, __hyp_stub_vectors
	msr	vbar_el2, x0					// 设置虚拟机管理程序异常向量表
	isb

	mov_q	x1, INIT_SCTLR_EL1_MMU_OFF

	/*
	 * Fruity CPUs seem to have HCR_EL2.E2H set to RES1,
	 * making it impossible to start in nVHE mode. Is that
	 * compliant with the architecture? Absolutely not!
	 */
	mrs	x0, hcr_el2
	and	x0, x0, #HCR_E2H
	cbz	x0, 1f							// 检查是否设置了E2H, 设置1表示el2运行了一个操作系统, 设置0表示el2运行了虚拟机管理程序

	/* Set a sane SCTLR_EL1, the VHE way */
	pre_disable_mmu_workaround
	msr_s	SYS_SCTLR_EL12, x1			// 设置mmu off下 vhe 模式系统控制寄存器各种功能和权限
	mov	x2, #BOOT_CPU_FLAG_E2H			// 设置boot cpu flag, vhe模式是虚拟机管理程序和操作系统都运行在el2
	b	2f								// vhe模式跳过 el1 系统控制寄存器设置, 因为用不到

1:
	pre_disable_mmu_workaround
	msr	sctlr_el1, x1					// 设置 el1 系统控制寄存器
	mov	x2, xzr
2:
	mov	w0, #BOOT_CPU_MODE_EL2
	orr	x0, x0, x2						// 设置当前 boot CPU mode
	eret
SYM_FUNC_END(init_kernel_el)

	/*
	 * This provides a "holding pen" for platforms to hold all secondary
	 * cores are held until we're ready for them to initialise.
	 */
SYM_FUNC_START(secondary_holding_pen)
	mov	x0, xzr
	bl	init_kernel_el			// w0=cpu_boot_mode
	mrs	x2, mpidr_el1
	mov_q	x1, MPIDR_HWID_BITMASK
	and	x2, x2, x1
	adr_l	x3, secondary_holding_pen_release
pen:	ldr	x4, [x3]
	cmp	x4, x2				// 比较待启动CPU id，core0初始化完系统后需要启动其他core
	b.eq	secondary_startup
	wfe
	b	pen
SYM_FUNC_END(secondary_holding_pen)

	/*
	 * Secondary entry point that jumps straight into the kernel. Only to
	 * be used where CPUs are brought online dynamically by the kernel.
	 */
SYM_FUNC_START(secondary_entry)	// Power State Coordination Interface,功耗节能热插拔模块调用此函数启动cpu
	mov	x0, xzr
	bl	init_kernel_el			// w0=cpu_boot_mode
	b	secondary_startup
SYM_FUNC_END(secondary_entry)

SYM_FUNC_START_LOCAL(secondary_startup)
	/*
	 * Common entry point for secondary CPUs.
	 */
	mov	x20, x0				// preserve boot mode
	bl	__cpu_secondary_check52bitva	// 检查是否支持52位虚地址
#if VA_BITS > 48
	ldr_l	x0, vabits_actual
#endif
	bl	__cpu_setup			// initialise processor
	adrp	x1, swapper_pg_dir
	adrp	x2, idmap_pg_dir
	bl	__enable_mmu
	ldr	x8, =__secondary_switched
	br	x8
SYM_FUNC_END(secondary_startup)

	.text
SYM_FUNC_START_LOCAL(__secondary_switched)
	mov	x0, x20
	bl	set_cpu_boot_mode_flag			// 设置cpu boot flag

	mov	x0, x20
	bl	finalise_el2

	str_l	xzr, __early_cpu_boot_status, x3
	adr_l	x5, vectors				// 设置中断向量表
	msr	vbar_el1, x5
	isb

	adr_l	x0, secondary_data
	ldr	x2, [x0, #CPU_BOOT_TASK]
	cbz	x2, __secondary_too_slow

	init_cpu_task x2, x1, x3

#ifdef CONFIG_ARM64_PTR_AUTH
	ptrauth_keys_init_cpu x2, x3, x4, x5
#endif

	bl	secondary_start_kernel
	ASM_BUG()
SYM_FUNC_END(__secondary_switched)

SYM_FUNC_START_LOCAL(__secondary_too_slow)
	wfe
	wfi
	b	__secondary_too_slow
SYM_FUNC_END(__secondary_too_slow)

/*
 * Sets the __boot_cpu_mode flag depending on the CPU boot mode passed
 * in w0. See arch/arm64/include/asm/virt.h for more info.
 */
SYM_FUNC_START_LOCAL(set_cpu_boot_mode_flag)
	adr_l	x1, __boot_cpu_mode
	cmp	w0, #BOOT_CPU_MODE_EL2
	b.ne	1f
	add	x1, x1, #4
1:	str	w0, [x1]			// Save CPU boot mode
	ret
SYM_FUNC_END(set_cpu_boot_mode_flag)

/*
 * The booting CPU updates the failed status @__early_cpu_boot_status,
 * with MMU turned off.
 *
 * update_early_cpu_boot_status tmp, status
 *  - Corrupts tmp1, tmp2
 *  - Writes 'status' to __early_cpu_boot_status and makes sure
 *    it is committed to memory.
 */
// cpu boot失败，记录失败原因到变量
	.macro	update_early_cpu_boot_status status, tmp1, tmp2
	mov	\tmp2, #\status
	adr_l	\tmp1, __early_cpu_boot_status
	str	\tmp2, [\tmp1]
	dmb	sy
	dc	ivac, \tmp1			// Invalidate potentially stale cache line
	.endm

/*
 * Enable the MMU.
 *
 *  x0  = SCTLR_EL1 value for turning on the MMU.
 *  x1  = TTBR1_EL1 value
 *  x2  = ID map root table address
 *
 * Returns to the caller via x30/lr. This requires the caller to be covered
 * by the .idmap.text section.
 *
 * Checks if the selected granule size is supported by the CPU.
 * If it isn't, park the CPU
 */
	.section ".idmap.text","a"
SYM_FUNC_START(__enable_mmu)
	mrs	x3, ID_AA64MMFR0_EL1
	ubfx	x3, x3, #ID_AA64MMFR0_EL1_TGRAN_SHIFT, 4	// 提取最小页粒度
	cmp     x3, #ID_AA64MMFR0_EL1_TGRAN_SUPPORTED_MIN
	b.lt    __no_granule_support						// CPU支持的页面粒度小于代码支持的最小页面粒度, boot failed
	cmp     x3, #ID_AA64MMFR0_EL1_TGRAN_SUPPORTED_MAX	// 超过CPU支持的最大粒度, failed
	b.gt    __no_granule_support
	phys_to_ttbr x2, x2
	msr	ttbr0_el1, x2			// load TTBR0
	load_ttbr1 x1, x1, x3

	set_sctlr_el1	x0			// x0寄存器保存了写系统控制寄存器的内容, mmu on已经打开

	ret
SYM_FUNC_END(__enable_mmu)

SYM_FUNC_START(__cpu_secondary_check52bitva)	// 对比cpu0初始化时的VA地址是否支持
#if VA_BITS > 48
	ldr_l	x0, vabits_actual
	cmp	x0, #52
	b.ne	2f

	mrs_s	x0, SYS_ID_AA64MMFR2_EL1
	and	x0, x0, #(0xf << ID_AA64MMFR2_EL1_VARange_SHIFT)
	cbnz	x0, 2f

	update_early_cpu_boot_status \
		CPU_STUCK_IN_KERNEL | CPU_STUCK_REASON_52_BIT_VA, x0, x1
1:	wfe
	wfi
	b	1b

#endif
2:	ret
SYM_FUNC_END(__cpu_secondary_check52bitva)

SYM_FUNC_START_LOCAL(__no_granule_support)
	/* Indicate that this CPU can't boot and is stuck in the kernel */
	update_early_cpu_boot_status \
		CPU_STUCK_IN_KERNEL | CPU_STUCK_REASON_NO_GRAN, x1, x2
1:
	wfe
	wfi
	b	1b
SYM_FUNC_END(__no_granule_support)

#ifdef CONFIG_RELOCATABLE
SYM_FUNC_START_LOCAL(__relocate_kernel)
	/*
	 * Iterate over each entry in the relocation table, and apply the
	 * relocations in place.
	 */
	adr_l	x9, __rela_start
	adr_l	x10, __rela_end
	mov_q	x11, KIMAGE_VADDR		// default virtual offset
	add	x11, x11, x23			// actual virtual offset, x23保存了之前计算的kernel随机空间地址偏移

// 循环修正 .rela section
0:	cmp	x9, x10
	b.hs	1f					// 判断使用的是 .rela还是 .relr section
	ldp	x12, x13, [x9], #24		// offset(重定位位置偏移), info(.dynsym符号索引，重定位类型), addend(加数), 每个8字节
	ldr	x14, [x9, #-8]			// 此时 x12 - offset, x13 - info, x14 - addend
	cmp	w13, #R_AARCH64_RELATIVE	// 检查重定位类型
	b.ne	0b
	add	x14, x14, x23			// relocate, addend加上kernel随机偏移
	str	x14, [x12, x23]			// 把重定位应用到offset
	b	0b

1:
#ifdef CONFIG_RELR
	/*
	 * Apply RELR relocations.
	 *
	 * RELR is a compressed format for storing relative relocations. The
	 * encoded sequence of entries looks like:
	 * [ AAAAAAAA BBBBBBB1 BBBBBBB1 ... AAAAAAAA BBBBBB1 ... ]
	 *
	 * i.e. start with an address, followed by any number of bitmaps. The
	 * address entry encodes 1 relocation. The subsequent bitmap entries
	 * encode up to 63 relocations each, at subsequent offsets following
	 * the last address entry.
	 *
	 * The bitmap entries must have 1 in the least significant bit. The
	 * assumption here is that an address cannot have 1 in lsb. Odd
	 * addresses are not supported. Any odd addresses are stored in the RELA
	 * section, which is handled above.
	 *
	 * Excluding the least significant bit in the bitmap, each non-zero
	 * bit in the bitmap represents a relocation to be applied to
	 * a corresponding machine word that follows the base address
	 * word. The second least significant bit represents the machine
	 * word immediately following the initial address, and each bit
	 * that follows represents the next word, in linear order. As such,
	 * a single bitmap can encode up to 63 relocations in a 64-bit object.
	 *
	 * In this implementation we store the address of the next RELR table
	 * entry in x9, the address being relocated by the current address or
	 * bitmap entry in x13 and the address being relocated by the current
	 * bit in x14.
	 */
	adr_l	x9, __relr_start
	adr_l	x10, __relr_end

2:	cmp	x9, x10
	b.hs	7f
	ldr	x11, [x9], #8
	tbnz	x11, #0, 3f			// branch to handle bitmaps
	add	x13, x11, x23
	ldr	x12, [x13]			// relocate address entry
	add	x12, x12, x23
	str	x12, [x13], #8			// adjust to start of bitmap
	b	2b

3:	mov	x14, x13
4:	lsr	x11, x11, #1
	cbz	x11, 6f
	tbz	x11, #0, 5f			// skip bit if not set
	ldr	x12, [x14]			// relocate bit
	add	x12, x12, x23
	str	x12, [x14]

5:	add	x14, x14, #8			// move to next bit's address
	b	4b

6:	/*
	 * Move to the next bitmap's address. 8 is the word size, and 63 is the
	 * number of significant bits in a bitmap entry.
	 */
	add	x13, x13, #(8 * 63)
	b	2b

7:
#endif
	ret

SYM_FUNC_END(__relocate_kernel)
#endif

SYM_FUNC_START_LOCAL(__primary_switch)
	adrp	x1, reserved_pg_dir			// 保留页表, 用于内核访问user space, SW PAN功能，内核把ttbr0设置为这个页表
	adrp	x2, init_idmap_pg_dir		// 全局页表 identity mapping
	bl	__enable_mmu					// 设置页表寄存器, 把x0写入系统控制寄存器, mmu on已打开
#ifdef CONFIG_RELOCATABLE
	adrp	x23, KERNEL_START			// 取 _text 4K对齐地址
	and	x23, x23, MIN_KIMG_ALIGN - 1
#ifdef CONFIG_RANDOMIZE_BASE
	mov	x0, x22				// x22, FDT blob identity mapping虚地址
	adrp	x1, init_pg_end
	mov	sp, x1
	mov	x29, xzr
	// arch/arm64/kernel/pi/kaslr_early.c
	bl	__pi_kaslr_early_init		// 生成random seed，使用该seed随机化内核load地址，避免利用已知内核内存布局攻击
	and	x24, x0, #SZ_2M - 1		// capture memstart offset seed
	bic	x0, x0, #SZ_2M - 1
	orr	x23, x23, x0			// record kernel offset， x23 存放内核地址随机化 offset
#endif
#endif
	// 清空旧内核image页表
	bl	clear_page_tables
	// 创建新的内核页表
	bl	create_kernel_mapping

	// 重新加载页表
	// 因为刚刚的页表是虚地址和物理地址一一对应的方式映射, 需要改成内核在高地址空间, 所以需要重新设置页表
	adrp	x1, init_pg_dir				// 全局页表，内核位于高地址
	load_ttbr1 x1, x1, x2
#ifdef CONFIG_RELOCATABLE
	bl	__relocate_kernel	// 重定位
#endif
	ldr	x8, =__primary_switched
	adrp	x0, KERNEL_START		// __pa(KERNEL_START)
	br	x8
SYM_FUNC_END(__primary_switch)
