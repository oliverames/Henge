/* HV_FAULT_BENCH=1: measures, once at boot, what a page fault and a page mapping cost in this
   process, to decide whether guest user memory can be mapped straight into our address space
   (loads and stores then run with no software TLB, and a missing or protected page faults in
   hardware instead). That only pays if a fault fixed up in-process is cheap next to the light
   refill it replaces. Results go to stderr (henge-native.log), one "fault-bench:" line each:
   - mprotect: changing one 16 KB page between none and read/write, no fault
   - signal fault: touch a protected page, a SIGBUS/SIGSEGV handler opens it and returns
   - mach fault: the same through an exception port on the faulting thread, handled by
     another thread, which never reaches a task-level port such as an attached debugger's
   - remap / remap+touch: vm_remap of one page over another (FIXED|OVERWRITE), then first use
   - largest reserve: the biggest stretch of address space one mmap can take
   A fault that never comes back (a debugger holding it) hangs the boot; the log line before
   says which test it was. Off unless HV_FAULT_BENCH is set. */
#include <mach/mach.h>
#include <mach/mach_error.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define PAGE (16u << 10)
#define NPAGES 256
#define ROUNDS 20

static uint8_t *region;
static double tick_ns;

static uint64_t now(void) { return mach_absolute_time(); }
static double ns_per(uint64_t t0, uint64_t t1, unsigned n) { return (double)(t1 - t0) * tick_ns / n; }

static int in_region(uintptr_t a) { return a >= (uintptr_t)region && a < (uintptr_t)region + (size_t)NPAGES * PAGE; }
static void open_page(uintptr_t a) { mprotect((void *)(a & ~(uintptr_t)(PAGE - 1)), PAGE, PROT_READ | PROT_WRITE); }

/* Touch every page of the closed region once; each touch faults and is opened by a handler. */
static void touch_all(void) {
    for (unsigned p = 0; p < NPAGES; p++) ((volatile uint8_t *)region)[(size_t)p * PAGE]++;
}

static double fault_round_ns(void) {
    uint64_t spent = 0;
    for (int r = 0; r < ROUNDS; r++) {
        mprotect(region, (size_t)NPAGES * PAGE, PROT_NONE);
        uint64_t t0 = now();
        touch_all();
        spent += now() - t0;
    }
    return (double)spent * tick_ns / (NPAGES * ROUNDS);
}

/* ---- signals ---- */
static struct sigaction prior_bus, prior_segv;
static volatile unsigned stray_signals;

static void on_fault(int sig, siginfo_t *si, void *uc) {
    (void)uc;
    if (in_region((uintptr_t)si->si_addr)) { open_page((uintptr_t)si->si_addr); return; }
    stray_signals++;
    sigaction(sig, sig == SIGBUS ? &prior_bus : &prior_segv, NULL); /* not ours: let the fault come again to the old one */
}

static void bench_signal(void) {
    struct sigaction sa = {0};
    sa.sa_sigaction = on_fault;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGBUS, &sa, &prior_bus);
    sigaction(SIGSEGV, &sa, &prior_segv);
    fprintf(stderr, "fault-bench: signal fault starting\n");
    double ns = fault_round_ns();
    sigaction(SIGBUS, &prior_bus, NULL);
    sigaction(SIGSEGV, &prior_segv, NULL);
    fprintf(stderr, "fault-bench: signal fault %.0f ns/fault (%u faults, %u stray)\n", ns, NPAGES * ROUNDS, stray_signals);
}

/* ---- Mach exception port on the faulting thread ---- */
#pragma pack(push, 4)
typedef struct {
    mach_msg_header_t head;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t thread, task;
    NDR_record_t ndr;
    exception_type_t exception;
    mach_msg_type_number_t code_count;
    int64_t code[2];
    mach_msg_trailer_t trailer;
} exc_request;
typedef struct {
    mach_msg_header_t head;
    NDR_record_t ndr;
    kern_return_t ret;
} exc_reply;
#pragma pack(pop)

static mach_port_t exc_port;
static volatile int exc_stop;
static volatile unsigned stray_exceptions;

static void *exc_server(void *arg) {
    (void)arg;
    for (;;) {
        exc_request req;
        if (mach_msg(&req.head, MACH_RCV_MSG, 0, sizeof req, exc_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL) != KERN_SUCCESS) break;
        if (req.head.msgh_id != 2405) { /* not mach_exception_raise: the stop message */
            if (exc_stop) break;
            continue;
        }
        uintptr_t addr = req.code_count > 1 ? (uintptr_t)req.code[1] : 0;
        kern_return_t ret = KERN_FAILURE; /* not ours: on to the next handler */
        if (in_region(addr)) open_page(addr), ret = KERN_SUCCESS;
        else stray_exceptions++;
        mach_port_deallocate(mach_task_self(), req.thread.name);
        mach_port_deallocate(mach_task_self(), req.task.name);
        exc_reply rep = {.head = {.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(req.head.msgh_bits), 0),
                                  .msgh_size = sizeof rep, .msgh_remote_port = req.head.msgh_remote_port,
                                  .msgh_id = req.head.msgh_id + 100},
                         .ndr = NDR_record, .ret = ret};
        mach_msg(&rep.head, MACH_SEND_MSG, sizeof rep, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    }
    return NULL;
}

static void bench_mach(void) {
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &exc_port);
    if (kr == KERN_SUCCESS) kr = mach_port_insert_right(mach_task_self(), exc_port, exc_port, MACH_MSG_TYPE_MAKE_SEND);
    thread_act_t self = mach_thread_self();
    if (kr == KERN_SUCCESS)
        kr = thread_set_exception_ports(self, EXC_MASK_BAD_ACCESS, exc_port, EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES,
                                        THREAD_STATE_NONE);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "fault-bench: mach fault unavailable: %s (%d)\n", mach_error_string(kr), kr);
        mach_port_deallocate(mach_task_self(), self);
        return;
    }
    pthread_t server;
    pthread_create(&server, NULL, exc_server, NULL);
    fprintf(stderr, "fault-bench: mach fault starting\n");
    double ns = fault_round_ns();
    thread_set_exception_ports(self, EXC_MASK_BAD_ACCESS, MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE);
    mach_port_deallocate(mach_task_self(), self);
    exc_stop = 1;
    mach_msg_header_t stop = {.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MAKE_SEND, 0), .msgh_size = sizeof stop,
                              .msgh_remote_port = exc_port, .msgh_id = 1};
    mach_msg(&stop, MACH_SEND_MSG, sizeof stop, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    pthread_join(server, NULL);
    mach_port_deallocate(mach_task_self(), exc_port); /* the send right */
    mach_port_mod_refs(mach_task_self(), exc_port, MACH_PORT_RIGHT_RECEIVE, -1);
    fprintf(stderr, "fault-bench: mach fault %.0f ns/fault (%u faults, %u stray)\n", ns, NPAGES * ROUNDS, stray_exceptions);
}

/* ---- mprotect and vm_remap without faults ---- */
static void bench_mprotect(void) {
    uint64_t t0 = now();
    for (int r = 0; r < ROUNDS; r++)
        for (unsigned p = 0; p < NPAGES; p++) {
            mprotect(region + (size_t)p * PAGE, PAGE, PROT_NONE);
            mprotect(region + (size_t)p * PAGE, PAGE, PROT_READ | PROT_WRITE);
        }
    fprintf(stderr, "fault-bench: mprotect %.0f ns/call\n", ns_per(t0, now(), 2 * NPAGES * ROUNDS));
}

static void bench_remap(void) {
    /* The guest's RAM stands in as a second region; each of our pages is replaced by one of its pages. */
    uint8_t *src = mmap(NULL, (size_t)NPAGES * PAGE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_SHARED, -1, 0);
    if (src == MAP_FAILED) { fprintf(stderr, "fault-bench: remap source mmap failed\n"); return; }
    memset(src, 1, (size_t)NPAGES * PAGE);
    uint64_t map = 0, touch = 0;
    kern_return_t bad = KERN_SUCCESS;
    for (int r = 0; r < ROUNDS && bad == KERN_SUCCESS; r++)
        for (unsigned p = 0; p < NPAGES; p++) {
            vm_address_t dst = (vm_address_t)(region + (size_t)p * PAGE);
            vm_prot_t cur, max;
            uint64_t t0 = now();
            kern_return_t kr = vm_remap(mach_task_self(), &dst, PAGE, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                                             mach_task_self(), (vm_address_t)(src + (size_t)((p + r) % NPAGES) * PAGE),
                                             FALSE, &cur, &max, VM_INHERIT_NONE);
            uint64_t t1 = now();
            if (kr != KERN_SUCCESS) { bad = kr; break; }
            ((volatile uint8_t *)region)[(size_t)p * PAGE]++;
            touch += now() - t1, map += t1 - t0;
        }
    if (bad != KERN_SUCCESS) fprintf(stderr, "fault-bench: remap failed: %s (%d)\n", mach_error_string(bad), bad);
    else
        fprintf(stderr, "fault-bench: remap %.0f ns/page, first touch after %.0f ns/page\n",
                (double)map * tick_ns / (NPAGES * ROUNDS), (double)touch * tick_ns / (NPAGES * ROUNDS));
    munmap(src, (size_t)NPAGES * PAGE);
}

/* The biggest single stretch of address space this process can reserve (a window for guest user memory needs one). */
static void bench_reserve(void) {
    size_t best = 0;
    void *at = NULL;
    for (int bits = 47; bits >= 30 && !best; bits--)
        for (int half = 1; half >= 0 && !best; half--) {
            size_t len = ((size_t)1 << bits) + (half ? (size_t)1 << (bits - 1) : 0);
            void *p = mmap(NULL, len, PROT_NONE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
            if (p != MAP_FAILED) best = len, at = p;
        }
    fprintf(stderr, "fault-bench: largest reserve %.1f GB at %p\n", best / 1073741824.0, at);
    if (best) munmap(at, best);
}

/* Always, at boot: the address range the kernel gave this process (the extended-virtual-addressing entitlement
   raises max_address). Too little shows up here, not later as a misleading out-of-space error. */
void hv_log_va_range(void) {
    task_vm_info_data_t vi;
    mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n) == KERN_SUCCESS)
        fprintf(stderr, "henge: address space %#llx-%#llx (%.0f GB)\n", (unsigned long long)vi.min_address,
                (unsigned long long)vi.max_address, (double)(vi.max_address - vi.min_address) / 1073741824.0);
}

void hv_fault_bench(void) {
    if (!getenv("HV_FAULT_BENCH")) return;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    tick_ns = (double)tb.numer / tb.denom;
    region = mmap(NULL, (size_t)NPAGES * PAGE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (region == MAP_FAILED) { fprintf(stderr, "fault-bench: mmap failed\n"); return; }
    memset(region, 0, (size_t)NPAGES * PAGE);
    bench_reserve();
    bench_mprotect();
    bench_mach();
    bench_signal();
    bench_remap();
    munmap(region, (size_t)NPAGES * PAGE);
}
