// Linux host smoke test for the shared iOS posix_spawn launcher. Pass the
// staged runtime's bin and data directories. No USB hardware or jobs are used.
#include "../../src/printing_ffi.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
extern int printing_ffi_ios_running(void);
extern void printing_ffi_ios_select_server(void);
int main(int argc, char **argv) {
    assert(argc == 4 || argc == 5);
    assert(!printing_ffi_ios_running());
    assert(start_cups_server(argv[3], "/missing/printing-ffi", argv[2], "") < 0);
    assert(!printing_ffi_ios_running());
    int port = start_cups_server(argv[3], argv[1], argv[2], "");
    if (port <= 0) { fprintf(stderr, "%s\n", get_last_error()); return 1; }
    assert(printing_ffi_ios_running());
    assert(start_cups_server(argv[3], argv[1], argv[2], "") == port);
    printing_ffi_ios_select_server();
    PrinterList *printers = get_printers();
    assert(printers != NULL);
    assert(printers->count == 0);
    free_printer_list(printers);
    if (argc == 5) {
        printf("READY %d\n", port);
        fflush(stdout);
        getchar(); // Test harness closes stdin to simulate app termination.
        return 0;
    }
    stop_cups_server();
    assert(!printing_ffi_ios_running());
    stop_cups_server();
    printing_ffi_ios_select_server();
    assert(get_print_jobs("DNP") == NULL);
    puts("PASS: missing helper, startup, reuse, IPP enumeration, shutdown/reap");
}
