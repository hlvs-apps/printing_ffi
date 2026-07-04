# Licensing — using printing_ffi (incl. the Android bundled-CUPS stack)

> Not legal advice. This is the well-established engineering interpretation of these
> licenses. For a shipping commercial product, have IP counsel confirm, especially the
> "mere aggregation" argument and the GPLv2-vs-v3 choice for Gutenprint.

## Can I use this in a closed-source app?

**Yes.** How clean it is depends on whether you bundle the Gutenprint dye-sub drivers.

### Config A — no Gutenprint (raw/POS/thermal + office/network IPP/driverless)
Fully clean, zero copyleft. Every component is permissive:

| Component | License | Closed-source app? |
|---|---|---|
| your application | your choice | — |
| `printing_ffi` plugin | MIT | fine |
| CUPS: `cupsd`, `libcups`, backends, filters, CGIs | Apache-2.0 | fine (may even link `libcups` into your app) |

No GPL is involved. This covers raw ESC/POS / ZPL printing and office/AirPrint/IPP printers.

### Config B — with Gutenprint (needed for DNP / dye-sub photo printers)
Still fine for a closed-source app, **because of how Gutenprint is used, not a special exception.**

| Component | License | Notes |
|---|---|---|
| Gutenprint: `libgutenprint`, `rastertogutenprint`, `backend_dnpds40` | **GPL-2.0-or-later** | runs as SEPARATE exec'd processes |
| libusb-1.0 (DNP USB transport) | LGPL-2.1-or-later | linked into the GPL backend, or dynamically linked |

## Why GPL Gutenprint does NOT infect your closed app

The GPL propagates only when GPL code is combined **into the same program**. Programs that
communicate "at arm's length" (separate processes via fork/exec, pipes, or sockets) are
separate works ("mere aggregation" — the FSF's own position). This project is arm's-length
by design:

```
your closed app  --IPP (socket)-->  cupsd  --fork/exec-->  rastertogutenprint + backend_dnpds40 (GPL)
   (your license)                 (Apache-2.0)                    (separate GPL processes)
```

Your app never links Gutenprint. It talks IPP to cupsd; cupsd forks the GPL filters/backend
as separate processes. The GPL stays contained to those binaries.

### THE HARD RULE
**Never link `libgutenprint` into your app's process** — no static link, no `dlopen` of it
into the app. The moment it shares your address space, aggregation no longer applies and your
app would have to be GPL. Keeping Gutenprint exec'd as a separate process is the license
firewall. (This is the reason the whole design uses cupsd + exec'd drivers instead of linking
drivers in.)

## Obligations in Config B (distribution duties — they do NOT make your app GPL)

1. **Ship or offer Gutenprint's complete corresponding source** for the exact version + any
   patches (reproducible via `tool/android/build-gutenprint.sh`, pinned to a specific release +
   SHA). A written offer valid 3 years, or accompany the distribution. This applies regardless
   of your app's license.
2. **Keep Gutenprint process-separated** (the hard rule above).
3. **Preserve notices**: Apache-2.0 requires keeping CUPS's NOTICE/attribution; LGPL libusb
   requires providing relink ability / its source.
4. **Pin Gutenprint to GPLv2.** It's "GPL-2.0-**or-later**," so you may elect v2. That avoids
   GPLv3 §6 "Installation Information" (anti-tivoization), which is awkward on a locked mobile
   app. Under v2 you owe source, not the ability to install modified versions.

## Runtime replacement of Gutenprint ("swap the lib via a dialog")

Not possible on stock Android. Android's W^X rule (API 29+) only lets you `exec` binaries from
the read-only, signed APK (`nativeLibraryDir`); you cannot `exec` a user-supplied binary from
writable storage. Replaceability (LGPL §4 / GPLv3 §6 spirit) is instead satisfied by the
**rebuild path**: the source + reproducible build script let a user build a modified Gutenprint
and rebuild/reinstall the app. Optional good-faith extra: the app can prefer a user-supplied
Gutenprint binary from a known path if present and executable (works on rooted/dev devices),
else fall back to the bundled one. Under GPLv2 (recommended pin) none of this is strictly
required beyond source availability.

## Summary
- Closed-source app: **yes.**
- Without Gutenprint: nothing copyleft; trivially clean (MIT + Apache-2.0).
- With Gutenprint for DNP: fine, provided it stays exec'd (never linked in), you ship/offer its
  source, and you pin to GPLv2.
