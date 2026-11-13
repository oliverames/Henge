/* Which macOS an IPSW is: ProductVersion and ProductBuildVersion from its BuildManifest.plist.
   Same idea as UTM asking VZMacOSRestoreImage (https://github.com/utmapp/UTM), here read with the
   libzip and libplist the restore stack already carries. */

#include "ipsw_info.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <zip.h>
#include <plist/plist.h>

static int manifest_string(plist_t manifest, const char *key, char *out, size_t len) {
    plist_t node = plist_dict_get_item(manifest, key);
    char *value = NULL;
    if (node) plist_get_string_val(node, &value);
    if (!value) return -1;
    snprintf(out, len, "%s", value);
    free(value);
    return 0;
}

int hv_ipsw_info(const char *path, char *version, size_t version_len, char *build, size_t build_len) {
    zip_t *zip = zip_open(path, ZIP_RDONLY, NULL);
    if (!zip) return -1;
    int result = -2;
    zip_stat_t st;
    if (zip_stat(zip, "BuildManifest.plist", 0, &st) == 0 && (st.valid & ZIP_STAT_SIZE) && st.size > 0 && st.size < (64u << 20)) {
        zip_file_t *f = zip_fopen(zip, "BuildManifest.plist", 0);
        char *data = f ? malloc(st.size) : NULL;
        if (data && zip_fread(f, data, st.size) == (zip_int64_t)st.size) {
            plist_t manifest = NULL;
            plist_from_memory(data, (uint32_t)st.size, &manifest, NULL);
            if (manifest && manifest_string(manifest, "ProductVersion", version, version_len) == 0 &&
                manifest_string(manifest, "ProductBuildVersion", build, build_len) == 0)
                result = 0;
            plist_free(manifest);
        }
        free(data);
        if (f) zip_fclose(f);
    }
    zip_close(zip);
    return result;
}
