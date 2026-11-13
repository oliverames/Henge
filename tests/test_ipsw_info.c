/* hv_ipsw_info reads the version and build from an IPSW's BuildManifest.plist: a synthetic zip with one,
   a zip without one, and a file that is no zip. */

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <zip.h>

#include "ipsw_info.h"

static const char manifest[] =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<plist version=\"1.0\"><dict>"
    "<key>ProductBuildVersion</key><string>24G222</string>"
    "<key>ProductVersion</key><string>15.7.2</string>"
    "<key>BuildIdentities</key><array/>"
    "</dict></plist>\n";

static void make_zip(const char *path, const char *name, const char *data) {
    int err = 0;
    zip_t *z = zip_open(path, ZIP_CREATE | ZIP_TRUNCATE, &err);
    assert(z);
    zip_source_t *src = zip_source_buffer(z, data, strlen(data), 0);
    assert(src && zip_file_add(z, name, src, ZIP_FL_ENC_UTF_8) >= 0);
    assert(zip_close(z) == 0);
}

int main(void) {
    char ok[] = "/tmp/hv_ipsw_ok_XXXXXX.zip", other[] = "/tmp/hv_ipsw_other_XXXXXX.zip", text[] = "/tmp/hv_ipsw_text_XXXXXX.txt";
    close(mkstemps(ok, 4)); close(mkstemps(other, 4)); close(mkstemps(text, 4));
    char version[32], build[32];

    make_zip(ok, "BuildManifest.plist", manifest);
    assert(hv_ipsw_info(ok, version, sizeof version, build, sizeof build) == 0);
    assert(!strcmp(version, "15.7.2") && !strcmp(build, "24G222"));

    make_zip(other, "readme.txt", "not a restore image");
    assert(hv_ipsw_info(other, version, sizeof version, build, sizeof build) == -2);

    FILE *f = fopen(text, "w");
    fputs("not a zip at all", f);
    fclose(f);
    assert(hv_ipsw_info(text, version, sizeof version, build, sizeof build) == -1);

    unlink(ok); unlink(other); unlink(text);
    puts("ipsw_info: ok");
    return 0;
}
