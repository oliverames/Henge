/* HV_EL0_WINDOW=bits: guest user memory mapped straight into this process.

   Each CPU reserves a window of 2^bits bytes. A guest user VA v below that is host address win_base + v, so a
   translated EL0 load or store becomes a range check and the access itself (translate.c, put_window), with no
   software TLB lookup. The window starts with nothing mapped. The first access to a page faults; the handler
   (hv_window_signal) looks the page up in the CPU's software TLB, the record of what the guest's page tables say:
   if the entry allows the access, the guest page's host memory is mapped into the window there (vm_remap, the
   same RAM, not a copy) and the access runs again; if not, the access goes to its TLB path instead, which walks
   the tables, faults into the guest, or reaches devices exactly as before. The instruction after a windowed access
   is ADR XZR, <its TLB path>: a no-op that tells the handler where that is.

   The window is a second TLB, so it is emptied when the software TLB is: a whole flush, a process switch (but for
   chunks HV_SHARED_KEEP keeps), a TLBI by page or range (from any CPU), and read-only where a page becomes code,
   so writes to it still take the slow path that notices code changing. Pages it holds are kept in a hash (by
   guest page) under a lock, so a drop from another CPU and this CPU's fault handler do not cross. */
#include "window.h"

#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/ucontext.h>

#include "machine.h"

#define WPAGE (1ull << HV_TLB_PAGE_BITS)
#define SLOTS 8192u /* hash slots: twice the pages it holds before starting over */
#define MAXPAGES (SLOTS / 2)

typedef struct HvWindow {
    uint8_t *base;
    uint64_t size;
    int lock;
    uint32_t n;
    struct { uint64_t va; const uint8_t *host; uint8_t rw; } slot[SLOTS]; /* va 0: empty (page 0 is never mapped) */
} HvWindow;

int hv_window_enabled(void) {
    return hv_knob[HV_K_EL0WINDOW];
}

static void lock(HvWindow *w) {
    while (__atomic_exchange_n(&w->lock, 1, __ATOMIC_ACQUIRE))
        while (__atomic_load_n(&w->lock, __ATOMIC_RELAXED)) {}
}
static void unlock(HvWindow *w) { __atomic_store_n(&w->lock, 0, __ATOMIC_RELEASE); }

static uint32_t hash(uint64_t va) { return (uint32_t)((va >> HV_TLB_PAGE_BITS) * 0x9e3779b97f4a7c15ull >> 51) & (SLOTS - 1); }

static int find(HvWindow *w, uint64_t va) {
    for (uint32_t i = hash(va), k = 0; k < SLOTS; i = (i + 1) & (SLOTS - 1), k++) {
        if (w->slot[i].va == va) return (int)i;
        if (!w->slot[i].va) return -1;
    }
    return -1;
}

/* Remove slot i, moving later entries of its run back (no tombstones). */
static void erase(HvWindow *w, uint32_t i) {
    w->slot[i].va = 0;
    w->n--;
    for (uint32_t j = (i + 1) & (SLOTS - 1); w->slot[j].va; j = (j + 1) & (SLOTS - 1)) {
        uint32_t h = hash(w->slot[j].va);
        /* j's entry moves back to i unless its home lies cyclically in (i, j] */
        int stays = i <= j ? h > i && h <= j : h > i || h <= j;
        if (!stays) {
            w->slot[i] = w->slot[j];
            w->slot[j].va = 0;
            i = j;
        }
    }
}

static void unmap_page(HvWindow *w, uint64_t va) {
    mmap(w->base + va, WPAGE, PROT_NONE, MAP_FIXED | MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
}

static void drop_all_locked(HvWindow *w) {
    if (!w->n) return;
    if (w->n > 64) {
        mmap(w->base, w->size, PROT_NONE, MAP_FIXED | MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    } else {
        for (uint32_t i = 0; i < SLOTS; i++)
            if (w->slot[i].va) unmap_page(w, w->slot[i].va);
    }
    for (uint32_t i = 0; i < SLOTS; i++) w->slot[i].va = 0;
    w->n = 0;
}

int hv_window_attach(HvCpu *cpu) {
    int bits = hv_window_enabled();
    if (!bits || !cpu->pc_state) return 0;
    if (cpu->pc_state->win) { /* a reset CPU: its window again, empty */
        hv_window_drop_all(cpu);
        cpu->win_base = (uint64_t)(uintptr_t)cpu->pc_state->win->base;
        return 0;
    }
    if (bits < 30 || bits > 40) return -1;
    HvWindow *w = calloc(1, sizeof *w);
    if (!w) return -1;
    w->size = 1ull << bits;
    void *p = mmap(NULL, w->size, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    if (p == MAP_FAILED) {
        free(w);
        return -1;
    }
    w->base = p;
    cpu->pc_state->win = w;
    cpu->win_base = (uint64_t)(uintptr_t)p;
    return 0;
}

int hv_window_reserve(HvMachine *m, int ncpus) {
    int bits = hv_window_enabled();
    if (!bits) return 0;
    for (int i = 0; i < ncpus && i < HV_MAX_CPUS; i++) {
        HvCpu probe = {0};
        probe.pc_state = &m->percpu[i];
        if (hv_window_attach(&probe) != 0) {
            fprintf(stderr, "henge: no room for %d CPUs' user-memory windows of %d bits; running without them\n", ncpus, bits);
            for (int j = 0; j < HV_MAX_CPUS; j++) {
                HvCpu q = {0};
                q.pc_state = &m->percpu[j];
                hv_window_detach(&q);
            }
            hv_knob[HV_K_EL0WINDOW] = 0;
            return -1;
        }
    }
    fprintf(stderr, "henge: user-memory windows: %d CPUs x %llu GB\n", ncpus, (unsigned long long)(1ull << bits) >> 30);
    return 0;
}

void hv_window_detach(HvCpu *cpu) {
    HvWindow *w = cpu->pc_state ? cpu->pc_state->win : NULL;
    if (!w) return;
    cpu->pc_state->win = NULL;
    cpu->win_base = 0;
    munmap(w->base, w->size);
    free(w);
}

void hv_window_drop_all(HvCpu *cpu) {
    HvWindow *w = cpu->pc_state ? cpu->pc_state->win : NULL;
    if (!w || !w->n) return;
    lock(w);
    drop_all_locked(w);
    unlock(w);
}

void hv_window_drop_except(HvCpu *cpu, uint64_t lo, const uint64_t *keep, uint32_t nchunks) {
    HvWindow *w = cpu->pc_state ? cpu->pc_state->win : NULL;
    if (!w || !w->n) return;
    lock(w);
    for (uint32_t i = 0; i < SLOTS;) {
        uint64_t va = w->slot[i].va, c = (va - lo) >> 25;
        if (va && !(c < nchunks && (keep[c / 64] >> (c % 64) & 1))) {
            unmap_page(w, va);
            erase(w, i); /* may move a later entry into i: look at i again */
            continue;
        }
        i++;
    }
    unlock(w);
}

void hv_window_drop_range(HvCpu *cpu, uint64_t va, uint64_t len) {
    HvWindow *w = cpu->pc_state ? cpu->pc_state->win : NULL;
    if (!w || !w->n) return;
    va &= 0x00ffffffffffffffull; /* tagged: by the low 56 bits, as the TLB */
    if (va >= w->size) return;
    uint64_t first = va & ~(WPAGE - 1), end = va + len < w->size ? va + len : w->size;
    lock(w);
    if ((end - first) >> HV_TLB_PAGE_BITS > SLOTS) { /* a big range: through the hash instead */
        for (uint32_t i = 0; i < SLOTS;) {
            uint64_t p = w->slot[i].va;
            if (p && p < end && p + WPAGE > first) {
                unmap_page(w, p);
                erase(w, i);
                continue;
            }
            i++;
        }
    } else {
        for (uint64_t p = first; p < end; p += WPAGE) {
            int i = find(w, p);
            if (i < 0) continue;
            unmap_page(w, p);
            erase(w, (uint32_t)i);
        }
    }
    unlock(w);
}

void hv_window_protect(HvCpu *cpu, const uint8_t *host_page) {
    HvWindow *w = cpu->pc_state ? cpu->pc_state->win : NULL;
    if (!w || !w->n) return;
    lock(w);
    for (uint32_t i = 0; i < SLOTS; i++)
        if (w->slot[i].va && w->slot[i].rw && w->slot[i].host == host_page) {
            mprotect(w->base + w->slot[i].va, WPAGE, PROT_READ);
            w->slot[i].rw = 0;
        }
    unlock(w);
}

static HvRam *ram_with(HvMachine *m, const uint8_t *host) {
    for (int i = 0; i < m->nram; i++)
        if ((uint64_t)(host - m->ram[i].host) < m->ram[i].size) return &m->ram[i];
    return NULL;
}

/* Map guest page va to host_page, read-write or read-only. 0 on success. */
static int map_page(HvWindow *w, uint64_t va, const uint8_t *host_page, int rw) {
    int i = find(w, va);
    if (i >= 0 && w->slot[i].host == host_page) { /* already there: only a write to a read-only one gets here */
        if (rw && !w->slot[i].rw) {
            if (mprotect(w->base + va, WPAGE, PROT_READ | PROT_WRITE)) return -1;
            w->slot[i].rw = 1;
        }
        return 0;
    }
    if (i >= 0) erase(w, (uint32_t)i);
    if (w->n >= MAXPAGES) drop_all_locked(w);
    vm_address_t dst = (vm_address_t)(uintptr_t)(w->base + va);
    vm_prot_t cur, max;
    if (vm_remap(mach_task_self(), &dst, WPAGE, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
                 (vm_address_t)(uintptr_t)host_page, FALSE, &cur, &max, VM_INHERIT_NONE) != KERN_SUCCESS)
        return -1;
    if (!rw && mprotect(w->base + va, WPAGE, PROT_READ)) {
        unmap_page(w, va);
        return -1;
    }
    uint32_t j = hash(va);
    while (w->slot[j].va) j = (j + 1) & (SLOTS - 1);
    w->slot[j].va = va, w->slot[j].host = host_page, w->slot[j].rw = (uint8_t)rw;
    w->n++;
    return 0;
}

int hv_window_signal(HvMachine *m, siginfo_t *info, void *ctx) {
    if (!m || !hv_window_enabled()) return 0;
    ucontext_t *uc = ctx;
    uint64_t pc = uc->uc_mcontext->__ss.__pc, x28 = uc->uc_mcontext->__ss.__x[28];
    HvCpu *cpu = NULL;
    for (int i = 0; i < m->ncpus && i < HV_MAX_CPUS; i++)
        if (m->cpus[i] && (uint64_t)(uintptr_t)m->cpus[i] == x28) cpu = m->cpus[i];
    HvWindow *w = cpu && cpu->pc_state ? cpu->pc_state->win : NULL;
    if (!w) return 0;
    uint64_t addr = (uint64_t)(uintptr_t)info->si_addr;
    if (addr - (uint64_t)(uintptr_t)w->base >= w->size) return 0;
    uint64_t rx = (uint64_t)(uintptr_t)m->jit.base;
    if (pc - rx >= (uint64_t)m->jit.capacity * 4 || pc + 4 - rx >= (uint64_t)m->jit.capacity * 4) return 0;
    uint32_t marker = *(const uint32_t *)(uintptr_t)(pc + 4);
    if ((marker & 0x9f00001fu) != 0x1000001fu) return 0; /* ADR XZR, <the TLB path> */
    int64_t off = (int64_t)((((uint64_t)marker >> 5 & 0x7ffff) << 2) | (marker >> 29 & 3)) << 43 >> 43;
    uint64_t tlb_path = pc + 4 + (uint64_t)off;

    uint64_t va = (addr - (uint64_t)(uintptr_t)w->base) & ~(WPAGE - 1);
    int write = (uc->uc_mcontext->__es.__esr >> 6) & 1; /* WnR */
    int done = 0;
    lock(w);
    HvTlbEntry *e = hv_tlb_ent(cpu, (va >> HV_TLB_PAGE_BITS) & (HV_TLB_SIZE - 1), 0);
    int r_ok = e->read_tag + HV_TLB_ADJ == va, w_ok = e->write_tag + HV_TLB_ADJ == va;
    if (va && !m->watch_va && !m->watch_pa && (write ? w_ok : r_ok)) {
        const uint8_t *host = (const uint8_t *)(uintptr_t)(va + (uint64_t)e->addend);
        HvRam *ram = ram_with(m, host);
        /* writable only where the TLB says so and the page holds no translated code (as tlb_fill's write_guard) */
        int rw = w_ok && ram && !ram->readonly && !__atomic_load_n(&ram->code_pages[(uint64_t)(host - ram->host) >> HV_TLB_PAGE_BITS], __ATOMIC_SEQ_CST);
        if (ram && (rw || !write) && map_page(w, va, host, rw) == 0) done = 1;
    }
    unlock(w);
    if (m->stats_interval) {
        if (done) m->stats.win_maps++;
        else m->stats.win_misses++;
    }
    if (!done) uc->uc_mcontext->__ss.__pc = tlb_path;
    return 1;
}
