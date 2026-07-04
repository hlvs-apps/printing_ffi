#ifndef PRINTING_FFI_H
#define PRINTING_FFI_H

// Add extern "C" guard to prevent C++ name mangling
#ifdef __cplusplus
extern "C"
{
#endif

#include <stdint.h>
#include <stdbool.h>

#if _WIN32
#include <windows.h>
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#include <pthread.h>
#include <unistd.h>
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default")))
#endif

    // Struct for returning printer information
    typedef struct
    {
        char *name;
        uint32_t state;
        char *url;
        char *model;
        char *location;
        char *comment;
        bool is_default;
        bool is_available;
    } PrinterInfo;

    typedef struct
    {
        int count;
        PrinterInfo *printers;
    } PrinterList;

    // Struct for returning print job information
    typedef struct
    {
        uint32_t id;
        char *title;
        uint32_t status;
    } JobInfo;

    typedef struct
    {
        int count;
        JobInfo *jobs;
    } JobList;

    // Struct for a single CUPS option choice
    typedef struct
    {
        char *choice;
        char *text;
    } CupsOptionChoice;

    // Struct for a list of CUPS option choices
    typedef struct
    {
        int count;
        CupsOptionChoice *choices;
    } CupsOptionChoiceList;

    // Struct for a single CUPS printer option
    typedef struct
    {
        char *name;
        char *default_value;
        CupsOptionChoiceList supported_values;
    } CupsOption;

    // Struct for a list of CUPS printer options
    typedef struct
    {
        int count;
        CupsOption *options;
    } CupsOptionList;

    // Struct for a single Windows paper source (bin)
    typedef struct
    {
        short id;
        char *name;
    } PaperSource;

    typedef struct
    {
        int count;
        PaperSource *sources;
    } PaperSourceList;

    // Struct for a single Windows media type
    typedef struct
    {
        short id;
        char *name;
    } MediaType;

    typedef struct
    {
        int count;
        MediaType *types;
    } MediaTypeList;

    // Structs for Windows printer capabilities
    typedef struct
    {
        short id;
        char *name;
        float width_mm;
        float height_mm;
    } PaperSize;

    typedef struct
    {
        int count;
        PaperSize *papers;
    } PaperSizeList;

    typedef struct
    {
        long x_dpi;
        long y_dpi;
    } Resolution;

    typedef struct
    {
        int count;
        Resolution *resolutions;
    } ResolutionList;

    typedef struct
    {
        PaperSizeList paper_sizes;
        PaperSourceList paper_sources;
        ResolutionList resolutions;
        MediaTypeList media_types;
        // New fields for color mode and orientation capabilities
        bool is_color_supported;
        bool is_monochrome_supported;
        bool supports_landscape;
    } WindowsPrinterCapabilities;

    FFI_PLUGIN_EXPORT int sum(int a, int b);
    FFI_PLUGIN_EXPORT int sum_long_running(int a, int b);
    FFI_PLUGIN_EXPORT PrinterList *get_printers(void);
    FFI_PLUGIN_EXPORT void free_printer_list(PrinterList *printer_list);
    FFI_PLUGIN_EXPORT PrinterInfo *get_default_printer(void);
    FFI_PLUGIN_EXPORT void free_printer_info(PrinterInfo *printer_info);
    FFI_PLUGIN_EXPORT int open_printer_properties(const char *printer_name, intptr_t hwnd);
    FFI_PLUGIN_EXPORT bool raw_data_to_printer(const char *printer_name, const uint8_t *data, int length, const char *doc_name, int num_options, const char **option_keys, const char **option_values);
    FFI_PLUGIN_EXPORT bool print_pdf(const char *printer_name, const char *pdf_file_path, const char *doc_name, int scaling_mode, int copies, const char *page_range, int num_options, const char **option_keys, const char **option_values, const char *alignment);
    FFI_PLUGIN_EXPORT JobList *get_print_jobs(const char *printer_name);
    FFI_PLUGIN_EXPORT void free_job_list(JobList *job_list);
    FFI_PLUGIN_EXPORT bool pause_print_job(const char *printer_name, uint32_t job_id);
    FFI_PLUGIN_EXPORT bool resume_print_job(const char *printer_name, uint32_t job_id);
    FFI_PLUGIN_EXPORT bool cancel_print_job(const char *printer_name, uint32_t job_id);
    FFI_PLUGIN_EXPORT CupsOptionList *get_supported_cups_options(const char *printer_name);
    FFI_PLUGIN_EXPORT void free_cups_option_list(CupsOptionList *option_list);
    FFI_PLUGIN_EXPORT WindowsPrinterCapabilities *get_windows_printer_capabilities(const char *printer_name);
    FFI_PLUGIN_EXPORT void free_windows_printer_capabilities(WindowsPrinterCapabilities *capabilities);
    FFI_PLUGIN_EXPORT const char *get_last_error();

    // --- Android: bundled cupsd scheduler (runs inside the app sandbox, app uid) ---
    // These are no-ops / return errors on non-Android platforms.
    //
    // start_cups_server: boots the bundled cupsd from the app sandbox. It creates
    //   the runtime dirs + config under `server_root`, builds the ServerBin symlink
    //   farm pointing at the extracted lib*.so executables in `native_lib_dir`,
    //   forks+execs `native_lib_dir/libcupsd.so`, waits until it answers IPP, then
    //   points the libcups client at it (cupsSetServer 127.0.0.1:<port>).
    //   server_root:    app-writable dir for config/spool/logs/state (e.g. filesDir/cups).
    //   native_lib_dir: applicationInfo.nativeLibraryDir (where the lib*.so live).
    //   data_dir:       dir containing share/cups/{mime,data,templates} extracted from assets.
    //   doc_root:       DocumentRoot for the web interface (static index.html/css/images
    //                   extracted from assets). May be NULL/"" to disable the web UI.
    //   Returns the chosen localhost port (>0) on success, or <0 on error
    //   (get_last_error has details).
    FFI_PLUGIN_EXPORT int32_t start_cups_server(const char *server_root, const char *native_lib_dir, const char *data_dir, const char *doc_root);

    // stop_cups_server: terminates the cupsd child started by start_cups_server.
    FFI_PLUGIN_EXPORT void stop_cups_server(void);

    // --- Android: USB file-descriptor delivery server (for the bundled Gutenprint
    //     DNP dye-sub backend) ---
    //
    // The whole Flutter app (Dart + this C FFI + Kotlin) runs in ONE process, and
    // cupsd + its backends are children forked from it (start_cups_server). So a
    // USB fd opened by the app (Kotlin UsbDeviceConnection.getFileDescriptor()) is
    // valid in the app process, and this C code can hand it to the backend child
    // over an AF_UNIX socket via SCM_RIGHTS.
    //
    // The patched DNP backend (backend_common.c, #ifdef __ANDROID__) reads the env
    // var PRINTING_FFI_USB_FD_SOCK (a FILESYSTEM AF_UNIX socket path — the same one
    // start_cups_server wires via a `SetEnv` in cups-files.conf), connects at JOB
    // DISPATCH, recvmsg's ONE data byte + a SCM_RIGHTS cmsg carrying a single USB
    // fd (CMSG_LEN(sizeof(int))), then libusb_set_option(NO_DEVICE_DISCOVERY) +
    // libusb_wrap_sys_device(fd). libusb OWNS the wrapped fd and closes it at job
    // end, so the server sends a dup() of a long-lived fd on EACH connection.
    //
    // start_usb_fd_server: unlink+create+bind+listen an AF_UNIX SOCK_STREAM socket
    //   at `sock_path` (use cups_usb_fd_sock_path() / <serverRoot>/usbfd.sock), then
    //   spawn a detached background thread that loops accept() and, for each
    //   connection, sendmsg's one payload byte + a SCM_RIGHTS cmsg carrying
    //   dup(usb_fd). One active server at a time (single printer). Does NOT take
    //   ownership of `usb_fd` (Kotlin/UsbDeviceConnection owns it); it only sends
    //   dups. Returns 0 on success, -1 on failure (get_last_error has details).
    //   No-op returning -1 on non-Android platforms.
    FFI_PLUGIN_EXPORT int start_usb_fd_server(const char *sock_path, int usb_fd);

    // stop_usb_fd_server: stops the accept thread and closes+unlinks the server
    //   socket. Does NOT close the caller's original usb_fd (owned by Kotlin) — only
    //   the dups the server created. Safe to call when no server is running.
    FFI_PLUGIN_EXPORT void stop_usb_fd_server(void);

    // cups_usb_fd_sock_path: the canonical AF_UNIX socket path the fd-server binds,
    //   the backend connects to, and the Kotlin layer must pass to
    //   start_usb_fd_server — computed as <server_root>/usbfd.sock from the most
    //   recent start_cups_server call. Returns a pointer to a static buffer, or NULL
    //   if start_cups_server has not run yet (Android). NULL on other platforms.
    FFI_PLUGIN_EXPORT const char *cups_usb_fd_sock_path(void);

    // generate_cups_dnp_ppd: (Android) generate — if not already present — a Gutenprint
    //   PPD for a specific DNP/Citizen dye-sub `driver` id (the DnpUsbManager "make"
    //   string, e.g. "dnp-dsrx1", "dnp-ds620"; matches src/xml/printers/dyesub.xml
    //   <printer driver="..."/>) and return its ABSOLUTE on-device path. Pass that path
    //   straight to add_cups_printer so it uploads the PPD file directly (no cups-driverd).
    //   Requires start_cups_server to have run. Returns a pointer to a static buffer, or
    //   NULL on failure (get_last_error). NULL / unsupported on non-Android platforms.
    FFI_PLUGIN_EXPORT const char *generate_cups_dnp_ppd(const char *driver);

    // add_cups_printer: creates/modifies a printer queue on the (local) CUPS server
    //   via the CUPS-Add-Modify-Printer IPP operation. `ppd_or_model` may be:
    //     - an ABSOLUTE path to a readable .ppd file -> the PPD FILE is uploaded
    //       directly (the `lpadmin -P` mechanism); cups-driverd is NOT invoked;
    //     - a model name such as "raw" (raw queue), "everywhere", or NULL;
    //     - any other ppd-name string, resolved server-side by cups-driverd.
    //   Returns true on success; get_last_error has details on failure.
    FFI_PLUGIN_EXPORT bool add_cups_printer(const char *name, const char *device_uri, const char *ppd_or_model);

    // remove_cups_printer: deletes a printer queue on the (local) CUPS server via
    //   the CUPS-Delete-Printer IPP operation. Idempotent: a "not found" result is
    //   treated as success (so it is safe to call on USB detach for an already-gone
    //   queue). Returns true on success; get_last_error has details on failure.
    FFI_PLUGIN_EXPORT bool remove_cups_printer(const char *name);

    // Functions that submit a job and return a job ID for status tracking.
    FFI_PLUGIN_EXPORT int32_t submit_raw_data_job(const char *printer_name, const uint8_t *data, int length, const char *doc_name, int num_options, const char **option_keys, const char **option_values);
    FFI_PLUGIN_EXPORT int32_t submit_pdf_job(const char *printer_name, const char *pdf_file_path, const char *doc_name, int scaling_mode, int copies, const char *page_range, int num_options, const char **option_keys, const char **option_values, const char *alignment);

    // Submit an arbitrary file (image, PDF, ...) letting CUPS auto-detect the
    // document format from the file contents. Returns the job id (>0) on success,
    // 0 on failure. Not supported on Windows. (macOS/Linux/Android via CUPS.)
    FFI_PLUGIN_EXPORT int32_t submit_file_job(const char *printer_name, const char *file_path, const char *doc_name, int num_options, const char **option_keys, const char **option_values);

    // Function to initialize the PDFium library. Must be called once on startup on Windows.
    FFI_PLUGIN_EXPORT void init_pdfium_library(void);
    FFI_PLUGIN_EXPORT void shutdown_pdfium_library(void);
    FFI_PLUGIN_EXPORT bool print_file_with_dialog(const char *file_path, const char *doc_name);

    // CUPS printer control functions (macOS/Linux only)
    FFI_PLUGIN_EXPORT bool cups_pause_printer(const char *printer_name, const char *username, const char *password);
    FFI_PLUGIN_EXPORT bool cups_resume_printer(const char *printer_name, const char *username, const char *password);
    FFI_PLUGIN_EXPORT bool cups_enable_printer(const char *printer_name, const char *username, const char *password);
    FFI_PLUGIN_EXPORT bool cups_disable_printer(const char *printer_name, const char *reason, const char *username, const char *password);
    FFI_PLUGIN_EXPORT bool cups_accept_jobs(const char *printer_name, const char *username, const char *password);
    FFI_PLUGIN_EXPORT bool cups_reject_jobs(const char *printer_name, const char *reason, const char *username, const char *password);

    // CUPS job control functions (macOS/Linux only)
    FFI_PLUGIN_EXPORT bool cups_hold_job(const char *printer_name, uint32_t job_id, const char *username, const char *password);
    FFI_PLUGIN_EXPORT bool cups_release_job(const char *printer_name, uint32_t job_id, const char *username, const char *password);
    FFI_PLUGIN_EXPORT bool cups_move_job(const char *source_printer, uint32_t job_id, const char *dest_printer, const char *username, const char *password);
    FFI_PLUGIN_EXPORT bool cups_set_job_priority(const char *printer_name, uint32_t job_id, int priority, const char *username, const char *password);

    // Struct for printer attribute query result
    typedef struct
    {
        char *attribute_name;
        char *attribute_value;
        int value_count;       // For array attributes
        char **array_values;   // For array attributes (NULL if value_count <= 1)
    } PrinterAttribute;

    typedef struct
    {
        int count;
        PrinterAttribute *attributes;
    } PrinterAttributeList;

    // CUPS printer attribute query functions (macOS/Linux/Android only)
    FFI_PLUGIN_EXPORT PrinterAttribute *cups_get_printer_attribute(const char *printer_name, const char *attribute_name, const char *username, const char *password);
    FFI_PLUGIN_EXPORT PrinterAttributeList *cups_get_printer_attributes(const char *printer_name, const char **attribute_names, int num_attributes, const char *username, const char *password);

    // cups_get_all_printer_attributes: query EVERY attribute the printer exposes.
    //   Sends an IPP Get-Printer-Attributes request with requested-attributes="all"
    //   and returns one PrinterAttribute per named attribute in the printer group
    //   (name + value(s), same value formatting as the functions above). Use this to
    //   discover which attribute names a printer supports without knowing them up
    //   front. Returns NULL on error (get_last_error has details). Not on Windows.
    FFI_PLUGIN_EXPORT PrinterAttributeList *cups_get_all_printer_attributes(const char *printer_name, const char *username, const char *password);
    FFI_PLUGIN_EXPORT void free_printer_attribute(PrinterAttribute *attribute);
    FFI_PLUGIN_EXPORT void free_printer_attribute_list(PrinterAttributeList *attribute_list);

#ifdef __cplusplus
}
#endif

#endif