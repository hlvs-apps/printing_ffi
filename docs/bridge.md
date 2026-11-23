# Fotobox print bridge (LAN CUPS host)

A stock (not jailbroken) iPad cannot drive a USB printer: an App Store app gets
no raw USB and may not spawn CUPS. The print bridge is the CUPS host it prints
to instead: a small Linux box on the booth LAN with the DNP/Citizen printer on
USB. The iOS app is the same CUPS client it is for the on-device daemon
([ios.md](ios.md)); only the address changes.

```
 iPad (App Store app)                 Raspberry Pi / any Debian box
 CupsIos  ──IPP over the LAN──▶  cupsd ─▶ imagetoraster ─▶ rastertogutenprint ─▶ USB ─▶ DNP
   finds it via DNS-SD                  ▲
   (_fotobox-cups._tcp)                 └── fotobox-cupsd: one queue per printer,
                                            page size from the loaded paper
```

It uses the distribution's CUPS and Gutenprint, not a bundled build. What the
package adds:

- `fotobox-cupsd` (`tool/cups_host/fotobox_cupsd.c`, built with
  `-DFOTOBOX_CUPS_SYSTEM`): the same queue manager as the iOS daemon. Every five
  seconds it runs Gutenprint's USB discovery and creates a queue for each
  supported printer, with the page size of the loaded paper as default (once),
  and makes the newest queue the default one. A systemd service,
  `fotobox-print-bridge.service`.
- `/etc/cups/cupsd.conf` for the LAN (the original is kept as
  `cupsd.conf.fotobox-orig` and restored on purge): listens on every interface,
  answers only `@LOCAL` subnets, shares queues, and requires HTTP Basic login as
  a member of the CUPS admin group on every request from the network.
- The CUPS user `fotobox-print` (system user, no login, member of `lpadmin`)
  whose password is the **bridge token**, in `/etc/fotobox-print-bridge/token`.
  The app signs in as this user; membership of `lpadmin` lets it pause, resume
  and re-enable the printer as it does on the device.
- An avahi service `_fotobox-cups._tcp` on port 631, so the app lists bridges
  and not every IPP printer on the network.
- `fotobox-print-bridge-pair`: prints the address, the token and a QR code of
  the pairing link `fotobox-cups://pair?server=<host>:631&token=<token>`.

## Security model

The booth LAN is the trust boundary (design decision D4). cupsd answers only
the box's own subnets and every network request needs the token. There is no
TLS: the iOS app's libcups is built without it, so the token crosses the LAN in
clear (HTTP Basic). Do not forward port 631 beyond the LAN. To change the token,
edit `/etc/fotobox-print-bridge/token` and run
`sudo dpkg-reconfigure fotobox-print-bridge`; re-pair the iPads.

## Install

On the box (Raspberry Pi OS, Debian 12+, Ubuntu 22.04+; any architecture):

```bash
sudo apt install gcc libcups2-dev dpkg-dev
git clone <printing_ffi> && cd printing_ffi
tool/bridge/build_bridge_deb.sh
sudo apt install ./build/bridge/fotobox-print-bridge_*.deb   # pulls cups, gutenprint, avahi
```

The install prints the pairing details. Show them again any time with
`sudo fotobox-print-bridge-pair` (pass an IP address to use it instead of
`<hostname>.local`). Plug in the printer; `journalctl -u fotobox-print-bridge`
shows the queue being created and the paper it found.

## Connecting an iPad

In the app's settings, under Print host: **Find print bridge** lists the
bridges on the LAN (iOS asks for Local Network access first), then asks for the
token. **Enter manually** takes `host[:port]` and the token, for networks that
block mDNS. Or scan the QR code with the Camera app: the link opens the app and
switches it to the bridge. **Use this iPad** goes back to the on-device daemon.
The choice is remembered on the iPad.

## Testing

`tool/bridge/test/run_bridge_test.sh [image]` (Docker, default
`debian:bookworm`) installs the distribution's CUPS, cups-filters and
Gutenprint in a container, builds and installs the package and replaces only
the USB backend with a stub (`stub-backend.sh`: one DS-RX1 with 6x4 paper). It
checks the user, token and configuration; that the queue appears as the default
with page size `w288h432`; that the app's CUPS client (`printing_ffi.c` built as
for iOS) is refused without a token and with a wrong one; that with the token it
finds the queue and prints a JPEG the way the app does, through the real
`imagetoraster` → `rastertogutenprint` chain, owned by `fotobox-print`; and that
a restart neither recreates the queue nor asks the printer again. The container
uses the host network with cupsd on port 1631, so the client reaches it as a LAN
client.

Not covered without hardware: a real DNP on USB, mDNS on a real LAN, and the iOS
side (Local Network prompt, DNS-SD browse, the Camera app opening the link).
