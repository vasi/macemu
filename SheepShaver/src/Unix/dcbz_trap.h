/*
 *  dcbz_trap.h - Emulate 32-byte dcbz on CPUs that zero a larger cache line
 *
 *  On PPC G3/G4 the `dcbz` instruction zeroes one 32-byte cache line. On PPC970
 *  ("G5") and other recent PowerPC chips the cache line is 128 bytes, so dcbz
 *  zeroes four times as much as legacy code expects. Apple worked around this
 *  for the Classic environment on G5 by setting HID5[7] (DCBZ32) from the OS X
 *  kernel; that bit isn't reachable from a hypervised guest like ours, so we
 *  instead emulate dcbz in software:
 *
 *    1. At startup, probe the actual dcbz behavior. If the CPU zeroes more than
 *       32 bytes, enable the workaround. Otherwise leave everything alone.
 *    2. When the workaround is enabled, scan ROM for dcbz instructions and
 *       replace each with `td 0, RA, RB` (trap doubleword). `td` is illegal in
 *       32-bit user mode, so executing it raises SIGILL.
 *    3. Mac RAM is allocated without PROT_EXEC. The first time MacOS jumps to
 *       a page in Mac RAM, we get a SIGSEGV; the handler scans that page for
 *       dcbz, replaces with td-trap, and makes the page executable.
 *    4. The SIGILL handler decodes the td-trap, computes the address dcbz was
 *       supposed to operate on, and zeroes exactly 32 bytes there (G3/G4
 *       semantics) — regardless of the CPU's real cache line size.
 */

#ifndef DCBZ_TRAP_H
#define DCBZ_TRAP_H

#include <stddef.h>
#include "sysdeps.h"   /* for uint32 */

#ifdef __cplusplus
extern "C" {
#endif

/* --- Inline helpers (used by callers in main_unix.cpp and rom_patches.cpp) --- */

/* True if `inst` is any dcbz (primary opcode 31, extended opcode 1014, RT=0). */
static inline bool is_dcbz(uint32 inst)
{
	return (inst & 0xfce007ffu) == 0x7c0007ecu;
}

/* True if `inst` is our td-trap marker: `td 0, RA, RB` (TO field = 0). */
static inline bool is_dcbz_td_trap(uint32 inst)
{
	return (inst & 0xffe007ffu) == 0x7c000088u;
}

/* Convert a dcbz instruction word to the corresponding td-trap encoding
 * (td 0, RA, RB) — the SIGILL handler decodes this back into RA/RB. */
static inline uint32 dcbz_to_td(uint32 dcbz)
{
	uint32 ra = (dcbz >> 16) & 0x1fu;
	uint32 rb = (dcbz >> 11) & 0x1fu;
	return 0x7c000088u | (ra << 16) | (rb << 11);
}

/* mtlr-r29 trap: a separate td encoding distinguishable from dcbz traps.
 * `td 31, r29, r29` = 0x7ffde888. TO=31, RA=RB=29 — picked so the SIGILL
 * handler can match exactly without ambiguity. Used to instrument the 68K
 * interpreter's dispatch to catch when r29 reaches a bogus value
 * (PPC970 0x50580000 crash). */
static inline bool is_mtlr_r29(uint32 inst)
{
	return inst == 0x7fa803a6u;	/* mtlr r29 = mtspr 8, r29 */
}

static inline bool is_mtlr_r29_trap(uint32 inst)
{
	return inst == 0x7ffde888u;
}

/* --- Runtime ---------------------------------------------------------------- */

/* Probe the CPU's dcbz behavior. Call once at startup, before any code that
 * depends on dcbz_needs_emulation(). Returns true if emulation is required. */
bool dcbz_trap_init(void);

/* True if dcbz on this CPU zeroes more than 32 bytes. Set by dcbz_trap_init(). */
bool dcbz_needs_emulation(void);

/* Scan [start, start+bytes) for dcbz instructions and replace each with the
 * td-trap that the SIGILL handler will emulate as a 32-byte zero. Returns the
 * number of replacements made. Caller is responsible for icache flushing if
 * the range is already in memory the CPU might cache. */
int dcbz_trap_patch_range(void *start, size_t bytes);

/* Handle a SIGSEGV that looks like an execute-fault on a Mac RAM page:
 * patch any dcbz in the page, mprotect it executable, flush icache. Returns
 * true if the fault was handled (caller should return immediately). */
bool dcbz_trap_handle_exec_fault(uint32 fault_addr, uint32 pc);

/* Scan [start, start+bytes) for `mtlr r29` instructions and replace each
 * with the td-trap that the SIGILL handler emulates (after sanity-checking
 * r29's value). Returns the number of replacements made. */
int mtlr_r29_trap_patch_range(void *start, size_t bytes);

#ifdef __cplusplus
}
#endif

#endif /* DCBZ_TRAP_H */
