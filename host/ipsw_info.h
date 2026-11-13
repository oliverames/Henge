#ifndef HENGEVM_IPSW_INFO_H
#define HENGEVM_IPSW_INFO_H

#include <stddef.h>

/* The macOS version and build a restore image is, read from the BuildManifest.plist at the top of the
   IPSW (a zip), not from its file name. 0 on success; -1 if the file is not a zip, -2 if it has no
   BuildManifest.plist or the manifest names no version and build. */
int hv_ipsw_info(const char *path, char *version, size_t version_len, char *build, size_t build_len);

#endif
