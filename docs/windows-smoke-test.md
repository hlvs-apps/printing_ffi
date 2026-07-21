# Windows manual smoke test

The Windows feature parity work (image printing, printer/job control, attribute
queries, per-job page counts) is native `winspool` + WIC + GDI code. It compiles in CI
(`.github/workflows/windows-build.yml`) and the Dart layer is covered by the mocked unit
tests, but the actual spooler/imaging behavior can only be verified on a real Windows
machine with a real (or virtual) printer. Run this checklist before shipping changes to
the Windows native path.

## Setup

1. A Windows 10/11 machine with at least one installed printer. A "Microsoft Print to
   PDF" queue works for most checks and needs no hardware.
2. `flutter run -d windows` from `example/`.
3. Pick a printer in the example app.

## Checklist

### Image printing
- [ ] Pick & print a **JPG** — the image prints, fit to the page, centered.
- [ ] Pick & print a **PNG with transparency** — transparent areas print **white**, not
      black (alpha is composited onto white).
- [ ] Pick & print a very **large photo** (e.g. 6000×4000) — it prints without running the
      app out of memory (WIC scales to the page before rasterizing).
- [ ] Print a **PDF** through the same "print file" path — still routes to the PDFium path
      and prints correctly (content sniffing: `%PDF` → PDF, else → image).
- [ ] Pick a **non-image, non-PDF** file (e.g. a `.txt`) — returns a clear error, no crash.

### Job control
- [ ] Submit a multi-page job, then **hold** it — it stops in the queue.
- [ ] **Release** the held job — it resumes printing.
- [ ] **Cancel** a job — it disappears from the queue (uses `JOB_CONTROL_DELETE`).
- [ ] **Change priority** of a queued job while several are waiting — higher priority
      moves ahead. Priority 100 is accepted (clamped to Windows' max of 99).

### Printer (queue) control
- [ ] **Pause the printer** — queued jobs stop printing.
- [ ] **Resume the printer** — they print again.
- [ ] **Disable / enable** the printer behave the same as pause/resume (documented alias).
- [ ] **Reject jobs** — the printer goes "work offline"; new submissions still enter the
      queue but do **not** print (this is the documented Windows best-effort; it is NOT a
      true refusal).
- [ ] **Accept jobs** — the printer comes back online and prints the queued jobs.

### Status, counts & attributes
- [ ] Query `queued-job-count` while N jobs are queued — returns N.
- [ ] Query `printer-state`, `printer-info`, `printer-location`, `printer-make-and-model`,
      `printer-is-accepting-jobs` — return sensible values.
- [ ] Query an **unmapped** attribute (e.g. `media-supported`) — returns "not available",
      no crash.
- [ ] "Get all attributes" — returns the curated Windows subset (~8–9 entries).

### Per-job page counts
- [ ] With a multi-page job printing, the job list shows **pages printed / total pages**
      advancing. A job with no page delimiters shows total = unknown (`-1`).

### Regression (things that must NOT have broken)
- [ ] Existing **PDF printing** still works (scaling modes, alignment, page ranges).
- [ ] Existing **raw data** printing still works.
- [ ] **cupsMoveJob** throws a clear "not supported on Windows" error.
- [ ] **printFileAndStreamStatus** throws a clear "not supported on Windows" error.
