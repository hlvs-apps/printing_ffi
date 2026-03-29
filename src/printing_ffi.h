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

    // Functions that submit a job and return a job ID for status tracking.
    FFI_PLUGIN_EXPORT int32_t submit_raw_data_job(const char *printer_name, const uint8_t *data, int length, const char *doc_name, int num_options, const char **option_keys, const char **option_values);
    FFI_PLUGIN_EXPORT int32_t submit_pdf_job(const char *printer_name, const char *pdf_file_path, const char *doc_name, int scaling_mode, int copies, const char *page_range, int num_options, const char **option_keys, const char **option_values, const char *alignment);

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

    // CUPS printer attribute query functions (macOS/Linux only)
    FFI_PLUGIN_EXPORT PrinterAttribute *cups_get_printer_attribute(const char *printer_name, const char *attribute_name, const char *username, const char *password);
    FFI_PLUGIN_EXPORT PrinterAttributeList *cups_get_printer_attributes(const char *printer_name, const char **attribute_names, int num_attributes, const char *username, const char *password);
    FFI_PLUGIN_EXPORT void free_printer_attribute(PrinterAttribute *attribute);
    FFI_PLUGIN_EXPORT void free_printer_attribute_list(PrinterAttributeList *attribute_list);

#ifdef __cplusplus
}
#endif

#endif