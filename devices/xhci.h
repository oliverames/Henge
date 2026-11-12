#ifndef HENGEVM_XHCI_H
#define HENGEVM_XHCI_H

#include <pthread.h>

#include "pcie.h"

/* An xHCI USB host controller (xHCI 1.0, one interrupter, 32-byte contexts,
   INTx) with three USB HID devices: a boot keyboard on port 1, a Magic
   Trackpad 2 on port 2 and a five-button wheel mouse on port 3: what
   Virtualization.framework gives a macOS guest as its "Virtual USB Keyboard",
   plus Apple's multitouch pad, so the guest's own gesture engine sees a real
   trackpad, plus a plain mouse for a real one held to the phone, so its right
   button is a right click and the guest's own Mouse settings apply to it.
   Changes come from the host UI on any thread (hv_xhci_key, hv_xhci_touch,
   hv_xhci_mouse); the CPU thread delivers them (hv_xhci_poll). */
#define HV_XHCI_SLOTS 8
#define HV_XHCI_PORTS 3
#define HV_XHCI_DEVICES 3
#define HV_XHCI_INTRS 4
#define HV_XHCI_EPS 32 /* device context index 1..31 */
#define HV_XHCI_REPORTS 256

/* The Magic Trackpad 2's sensor, in its own units (a ~160 x 115 mm pad).
   hv_xhci_touch takes coordinates in these ranges. */
#define HV_TP_SENSOR_X 8134
#define HV_TP_SENSOR_Y 5206
#define HV_TP_FINGERS 10
#define HV_TP_REPORTS 64
#define HV_TP_REPORT_LEN (12 + 9 * HV_TP_FINGERS) /* report ID 2: 12-byte prefix, N x 9-byte fingers */
/* The mouse's report: buttons 1-5, X and Y (16 bits each, relative), wheel, horizontal pan. */
#define HV_MS_REPORT_LEN 7
#define HV_MS_REPORTS 128

typedef struct HvXhciRing {
    uint64_t dequeue; /* guest PA of the next TRB */
    int ccs;          /* consumer cycle state */
} HvXhciRing;

typedef struct HvXhci {
    HvPciDev pci;
    HvMachine *m;
    /* operational */
    uint32_t usbcmd, usbsts, dnctrl, config;
    uint64_t dcbaap;
    HvXhciRing cmd;
    int cmd_running;
    uint32_t portsc[HV_XHCI_PORTS];
    /* interrupters and their event rings (macOS's driver wants at least three) */
    struct HvXhciIntr {
        uint32_t iman, imod, erstsz;
        uint64_t erstba, erdp;
        uint64_t seg_base;  /* current event ring segment */
        uint32_t seg_size, seg_index, index;
        int pcs;
    } intr[HV_XHCI_INTRS];
    /* device slots: -1 until the device on the slot's port is addressed */
    int slot_used[HV_XHCI_SLOTS + 1];
    struct HvXhciSlot {
        int dev;         /* 0 keyboard, 1 trackpad, 2 mouse, -1 none */
        int configured;
        HvXhciRing ep[HV_XHCI_EPS];
        int ep_running[HV_XHCI_EPS];
    } slots[HV_XHCI_SLOTS + 1];
    /* keyboard reports waiting for an IN transfer (8 bytes each) */
    pthread_mutex_t mu;
    uint8_t reports[HV_XHCI_REPORTS][8];
    uint32_t rhead, rtail;
    uint8_t state[8];      /* modifiers, reserved, six keys: the current report */
    uint64_t delivered;
    /* Magic Trackpad 2: the fingers on the pad and their reports (Apple
       multitouch format, report ID 2: 12-byte prefix plus 9 bytes a finger). */
    struct HvTpFinger {
        int in;
        int id;        /* the report's 4-bit touch ID, 1..15 */
        int x, y;      /* sensor coordinates, 0..HV_TP_SENSOR_X/Y */
        uint8_t state; /* the report's 3-bit state: 0 none, 3 near, 4 contact, 7 stop */
    } tp_fingers[HV_TP_FINGERS];
    int tp_button;     /* the pad's full press (report byte 1, bit 0) */
    uint32_t tp_ts;    /* the report timestamp, one per report */
    uint8_t tp_reports[HV_TP_REPORTS][HV_TP_REPORT_LEN];
    uint8_t tp_rlen[HV_TP_REPORTS];
    uint32_t tp_rhead, tp_rtail;
    int tp_mt;         /* the guest switched us to multitouch mode (feature report 2) */
    uint64_t tp_delivered;
    uint32_t tp_reqs;   /* control requests logged, capped */
    uint32_t tp_db;     /* doorbells logged, capped */
    uint32_t tp_multi_logs; /* multi-finger deliveries logged, capped */
    uint8_t tp_f1[8];   /* feature report 1: the header for the selected sensor register */
    int tp_f1_len;
    /* The mouse on port 3: its reports, oldest first, and the buttons held now. */
    uint8_t ms_reports[HV_MS_REPORTS][HV_MS_REPORT_LEN];
    uint32_t ms_rhead, ms_rtail;
    uint8_t ms_buttons;
    int ms_unplugged; /* HV_USB_MOUSE=0: nothing on port 3 */
} HvXhci;

HvXhci *hv_xhci_create(HvMachine *m, HvPcie *bus);
/* Any thread: a key went down or up (HID usage page 7 usage, e.g. 4 = A; 0xe0-0xe7 are modifiers). */
void hv_xhci_key(HvXhci *x, uint8_t usage, int down);
/* The same, by Linux input key code (what the host UI produces). */
void hv_xhci_key_linux(HvXhci *x, uint16_t code, int down);
/* Any thread: a Magic Trackpad 2 touch. phase: 0 down, 1 move, 2 up. id: a
   stable 1..15 for this touch; x, y in sensor units (HV_TP_SENSOR_*). Down and up
   report at once; a move only updates the finger, and hv_xhci_touch_frame commits
   one report for all the fingers that moved together. ts_ms is the touch sample's
   own clock (ms); the guest divides position deltas by timestamp deltas to get
   speed, so it must be the sample time, not the moment we happen to process it. */
void hv_xhci_touch(HvXhci *x, int id, int phase, int px, int py, uint32_t ts_ms);
/* Any thread: send one frame with every finger's current state (ends a move batch),
   stamped with the touch sample's own clock (ms). */
void hv_xhci_touch_frame(HvXhci *x, uint32_t ts_ms);
/* Any thread: the pad's full press (a click), down or up. */
void hv_xhci_touch_button(HvXhci *x, int down);
/* Any thread: the mouse moved, scrolled or both. wheel is positive away from the user, pan
   positive to the right, both in detents. Moves are merged while the guest hasn't taken them. */
void hv_xhci_mouse(HvXhci *x, int dx, int dy, int wheel, int pan);
/* Any thread: the mouse's buttons, bit 0 primary, 1 secondary, 2 middle, 3 back, 4 forward. */
void hv_xhci_mouse_buttons(HvXhci *x, unsigned buttons);
/* Whether the guest has configured the mouse and is reading it: until then its input belongs elsewhere. */
int hv_xhci_mouse_ready(const HvXhci *x);
/* CPU thread: hand waiting reports to the guest. */
void hv_xhci_poll(HvXhci *x);

#endif
