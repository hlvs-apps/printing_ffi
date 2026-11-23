// The iOS app's CUPS client (printing_ffi.c built with PRINTING_FFI_IOS), run
// against the bridge: configure host + credentials, probe, then print a JPEG
// the way FfiPrintBackend.submitPrintJob does.
//   client_test <host:port> <user> <token> [jpeg]
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include "printing_ffi.h"
extern void printing_ffi_ios_configure_server(const char *server);
extern void printing_ffi_ios_configure_credentials(const char *user, const char *password);
extern void printing_ffi_ios_select_server(void);
extern int32_t printing_ffi_ios_probe(char *q, size_t qc, char *m, size_t mc);
int main(int argc, char **argv) {
    char queue[256], model[256];
    printing_ffi_ios_configure_server(argv[1]);
    printing_ffi_ios_configure_credentials(argv[2], argv[3]);
    int found = printing_ffi_ios_probe(queue, sizeof queue, model, sizeof model);
    printf("probe=%d queue='%s' model='%s' error='%s'\n", found, found > 0 ? queue : "",
           found > 0 ? model : "", get_last_error());
    if (found <= 0 || argc < 5) return found > 0 ? 0 : 1;
    printing_ffi_ios_select_server();
    const char *keys[] = {"media", "orientation-requested"};
    const char *values[] = {"w288h432", "3"};
    bool ok = print_pdf(queue, argv[4], "fotobox-bridge-test", 0, 1, NULL, 2, keys, values, NULL);
    JobList *jobs = get_print_jobs(queue);
    printf("submit=%d jobs=%d\n", ok, jobs ? jobs->count : -1);
    return ok ? 0 : 1;
}
