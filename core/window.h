#ifndef HENGEVM_WINDOW_H
#define HENGEVM_WINDOW_H

#include <signal.h>
#include <stdint.h>

#include "cpu.h"

/* HV_EL0_WINDOW=bits: guest user memory mapped straight into this process (see window.c). */

struct HvMachine;

int hv_window_enabled(void);                  /* bits, or 0 */
/* Up front, before any code is translated: every CPU's window, or none (the knob goes off). */
int hv_window_reserve(struct HvMachine *m, int ncpus);
int hv_window_attach(HvCpu *cpu);             /* cpu's window (made if missing: tests), emptied; 0 on success or when off */
void hv_window_detach(HvCpu *cpu);
void hv_window_drop_all(HvCpu *cpu);
/* Every page but those in the 32 MB chunks set in keep (bit c: lo + c * 32 MB), as a process switch keeps them. */
void hv_window_drop_except(HvCpu *cpu, uint64_t lo, const uint64_t *keep, uint32_t nchunks);
void hv_window_drop_range(HvCpu *cpu, uint64_t va, uint64_t len); /* any CPU's thread */
void hv_window_protect(HvCpu *cpu, const uint8_t *host_page);     /* page became code: read-only wherever mapped */
/* A host fault: 1 if it was an access through a window (handled: the context now retries it, or goes to the
   access's TLB path), 0 if not. From the SIGBUS/SIGSEGV handler. */
int hv_window_signal(struct HvMachine *m, siginfo_t *info, void *ctx);

#endif
