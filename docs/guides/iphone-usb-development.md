# Install Heeler Dev through a Linux laptop

The Mac builds and signs; the Linux laptop carries the iPhone's USB connection.
The phone does not need to be attached to the Mac, and nothing goes to TestFlight.

## Fork identity

- App: `dev.ricardofelixb.heeler`, displayed as **Heeler Dev**.
- Team: `5XNKUB5FEE`.
- Extensions: `.NotificationService` and `.Widgets` under the app identifier.
- App Group: `group.dev.ricardofelixb.heeler.shared`.
- URL handler: `heeler-dev://`, leaving upstream's `heeler://` handler alone.

Installing this identifier does not replace upstream Heeler or share its app
container or Keychain. Pair your hosts again in the new app. Parsing an
upstream-format link remains supported internally, but the fork does not
register that URL scheme with iOS.

## One-time preparation

On the Mac:

1. Sign in under **Xcode → Settings → Accounts** with the Apple account for the
   paid team above. An installed signing certificate alone does not sign Xcode
   into the developer portal.
2. Register the iPhone's UDID in [Apple Developer → Devices](https://developer.apple.com/account/resources/devices/list).
   `idevice_id -l` on the Linux laptop reports that UDID. Existing registrations
   can be reused; do not register the same phone again.
3. Keep the Apple Development certificate and its private key on the Mac.
   Automatic signing creates the three application profiles and their shared
   App Group. Do not substitute a wildcard profile: it cannot grant App Groups
   or Push Notifications.

On Omarchy/Arch Linux:

```sh
sudo pacman -S --needed usbmuxd libimobiledevice ideviceinstaller
```

Unplug the iPhone, unlock it, reconnect directly, then tap **Trust** when asked:

```sh
idevice_id -l
idevicepair pair
idevicepair validate
```

Reconnecting after installing usbmuxd applies its USB permissions. If the phone
is absent from `idevice_id -l`, inspect the hardware and daemon before changing
pairing records:

```sh
grep -H . /sys/bus/usb/devices/*/product
sudo journalctl -u usbmuxd -b -n 25 --no-pager
```

## Build on the Mac

From this repository:

```sh
make ipa
```

This generates the checked-in project, creates a Debug archive at
`build/Heeler-Dev.xcarchive`, then exports a development-signed IPA under
`build/device-export/`. It reuses `.ci/source-packages` and never uploads.

Apple documents the registered-device workflow under
[distributing to registered devices](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices).
The export uses Xcode's **Debugging** method, not App Store distribution. The
phone must appear in every embedded provisioning profile, including extensions.

## Copy and install on the Linux laptop

```sh
scp ricardo@ricardos-mac-mini:Projects/forks/Heeler/build/device-export/Heeler.ipa .
ideviceinstaller install Heeler.ipa
```

Current [ideviceinstaller releases](https://github.com/libimobiledevice/ideviceinstaller/releases)
use subcommands. Check `ideviceinstaller --help` on an older package, which may
use `-i Heeler.ipa` instead.

Enable **Developer Mode** on the iPhone when prompted (Settings → Privacy &
Security → Developer Mode, followed by a restart and confirmation). If that
setting is initially absent, attempt installation first. Open **Heeler Dev**,
not the original Heeler, and pair a host to check SSH, the Console, and Pi
conversation rendering. Linux USB installation does not automatically launch
the app.

## Boundaries

- Do not copy signing private keys or `/var/lib/lockdown` pairing records between
  machines. Only the exported IPA moves.
- Development profiles expire; rebuild with a current profile when necessary.
- The upstream App Store/TestFlight release pipeline and production APNs relay
  have not been configured for this fork. A successful local install does not
  prove fork push-notification delivery.
