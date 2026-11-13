/* The engine calls DisplayRouter makes, so the router can be tested on a Mac without the engine. */
#include <stdint.h>
void henge_vm_set_display_layer(void *layer);
void henge_vm_set_display_live(uint32_t width, uint32_t height, float px_per_mm);
int henge_vm_display_size(uint32_t *width, uint32_t *height);
