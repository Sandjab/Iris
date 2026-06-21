// iris-sandbox-exec — minimal Seatbelt exec-shim for IRIS plugins.
//
// Usage: iris-sandbox-exec <profile-path> <plugin-executable> [args...]
//
// Reads an SBPL profile from <profile-path>, applies it to the current
// process via sandbox_init_with_parameters (Seatbelt SPI — the same path
// Chromium uses; see docs/plugins-design.md §6), then execv()s the plugin so
// the sandbox is inherited across exec. Deny-by-default lives in the profile,
// not here.
//
// Exit codes are chosen to be distinct from typical child codes:
//   64 usage, 70 internal (profile read / sandbox apply), 71 exec failure.

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Seatbelt SPI — not in a public header; declared here as Chromium does.
// flags == 0 means `profile` is a raw SBPL string (SANDBOX_STRING).
extern int sandbox_init_with_parameters(const char *profile,
                                        uint64_t flags,
                                        const char *const parameters[],
                                        char **errorbuf);
extern void sandbox_free_error(char *errorbuf);

static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long size = ftell(f);
    if (size < 0) { fclose(f); return NULL; }
    rewind(f);
    char *buf = malloc((size_t)size + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t n = fread(buf, 1, (size_t)size, f);
    int read_err = ferror(f);
    fclose(f);
    if (read_err || n != (size_t)size) {
        free(buf);
        return NULL;
    }
    buf[n] = '\0';
    return buf;
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "usage: iris-sandbox-exec <profile-path> <executable> [args...]\n");
        return 64;
    }
    const char *profile_path = argv[1];
    const char *executable = argv[2];

    char *profile = read_file(profile_path);
    if (!profile) {
        fprintf(stderr, "iris-sandbox-exec: cannot read profile '%s': %s\n",
                profile_path, strerror(errno));
        return 70;
    }

    char *errbuf = NULL;
    int rc = sandbox_init_with_parameters(profile, 0, NULL, &errbuf);
    free(profile);
    if (rc != 0) {
        fprintf(stderr, "iris-sandbox-exec: sandbox_init failed: %s\n",
                errbuf ? errbuf : "(unknown)");
        if (errbuf) sandbox_free_error(errbuf);
        return 70;
    }

    // execv inherits the sandbox. argv[2..] (NULL-terminated by the OS)
    // becomes the child's argv, so argv[2] is also the child's argv[0].
    execv(executable, &argv[2]);
    fprintf(stderr, "iris-sandbox-exec: execv '%s' failed: %s\n",
            executable, strerror(errno));
    return 71;
}
