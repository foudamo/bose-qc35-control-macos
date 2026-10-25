# Bose QC35 Control for macOS

A tiny menu bar app for macOS that controls noise cancelling (**High / Low / Off**) on **first-generation Bose QuietComfort 35** headphones and shows their battery level, without the Bose app.

It's a native Swift app that uses Apple's IOBluetooth framework. The Bluetooth protocol comes from [SaorCon](https://github.com/platinum95/SaorCon) (see [Acknowledgments](#acknowledgments)).

## Features

- Switch noise cancelling between High, Low and Off from the menu bar
- Battery level, refreshed when you open the menu and every 5 minutes
- Connects automatically whenever the headphones connect to your Mac
- Pick which paired headphones to control (useful if you've renamed them)
- Optional Launch at Login
- No Dock icon, no background services, no network access

## Requirements

- macOS 14 Sonoma or newer (developed for macOS 15.7.4)
- Apple silicon or Intel Mac
- Bose QuietComfort 35 (first generation), paired with the Mac
- Apple's Command Line Tools (free; the full Xcode app is **not** needed)

It may also work with the QC35 II and other Bose headphones that use the same protocol, but only the first-generation QC35 has been tested.

## Getting started

### 1. Install the Command Line Tools

Open **Terminal** (Applications › Utilities › Terminal) and run:

```sh
xcode-select --install
```

Click **Install** in the window that appears. If it says the tools are already installed, you're all set.

### 2. Download the code

```sh
git clone https://github.com/foudamo/bose-qc35-control-macos.git
cd bose-qc35-control-macos
```

Or download the ZIP from the green **Code** button on GitHub, unzip it, and `cd` into the folder in Terminal.

### 3. Build and install

```sh
chmod +x build.sh
./build.sh --install
```

This compiles the app, copies **QC35 Control.app** into `/Applications`, and launches it. A headphones icon appears in the menu bar.

To build without installing, run `./build.sh` on its own; the app ends up in the `build` folder.

### 4. Allow Bluetooth access

The first time the app connects, macOS asks whether QC35 Control may use Bluetooth. Click **Allow**.

If you missed the prompt, turn it on in **System Settings › Privacy & Security › Bluetooth**.

## Using it

1. Connect your QC35 to the Mac as usual (Bluetooth menu or System Settings).
2. Click the headphones icon in the menu bar.
3. Choose **High**, **Low** or **Off**. With the menu open, you can also press **1**, **2** or **3**.

The checkmark shows the level the headphones actually reported back, so it's always the true state. The icon looks dimmed while the headphones aren't connected.

Other menu items:

| Item | What it does |
|---|---|
| **Headphones** | Choose which paired device to control. *Auto-detect Bose* (the default) picks a device whose name contains "Bose", "QC35" or "QuietComfort". |
| **Reconnect** | Drops and reopens the connection to the headphones. |
| **Launch at Login** | Starts the app automatically when you log in. |

## Updating

```sh
cd bose-qc35-control-macos
git pull
./build.sh --install
```

macOS may ask for Bluetooth permission again after a rebuild, because the app is signed locally ("ad-hoc") and its signature changes each build.

## Uninstalling

1. Quit the app from its menu.
2. If you turned on Launch at Login, turn it off first (or remove it in System Settings › General › Login Items).
3. Delete **QC35 Control** from `/Applications`.
4. Optionally remove its settings: `defaults delete local.qc35control`

## Troubleshooting

**The menu says "Not connected" while the headphones are playing audio.**
Click **Reconnect**. If the Bose Connect app or another headphone tool is running, quit it, since only one app can use the control channel at a time.

**"No Bose headphones paired."**
Your headphones may have a custom name. Open **Headphones** in the menu and pick them from the list.

**No Bluetooth permission prompt appeared, or nothing happens.**
Check System Settings › Privacy & Security › Bluetooth and make sure QC35 Control is allowed. If it's listed but still not working, remove it from that list, then quit and reopen the app.

**Choosing Low doesn't change anything.**
Some early QC35 firmware only supports High and Off. Updating the headphones' firmware with Bose's tools may add Low.

**`./build.sh: Permission denied`**
Run `chmod +x build.sh` first.

**`swiftc not found`**
Install the Command Line Tools (step 1).

**Seeing what the app is doing**
```sh
log stream --predicate 'process == "QC35Control"'
```

## How it works

The headphones expose a Bose control service on Bluetooth RFCOMM channel 8. Every packet, in both directions, is:

```
[3-byte command code] [1-byte payload length] [payload]
```

| Purpose | App sends | Headphones reply |
|---|---|---|
| Handshake | `00 01 01 00` | `00 01 03 …` |
| Query status | `01 01 05 00` | several messages, including the ANC level |
| Query battery | `02 02 01 00` | `02 02 03 01 <percent>` |
| Set noise cancelling | `01 06 02 01 <level>` | `01 06 03 02 <level> ..` |

Noise-cancelling level byte: `01` = High, `03` = Low, `00` = Off.

### Project layout

| File | Purpose |
|---|---|
| `Sources/BoseConnection.swift` | RFCOMM connection and the Bose protocol |
| `Sources/AppController.swift` | Menu bar icon, menu, device selection, reconnection |
| `Sources/main.swift` | App entry point |
| `Info.plist` | App bundle settings, including the Bluetooth permission text |
| `build.sh` | Compiles, bundles, signs and optionally installs the app |

## Acknowledgments

The Bose control protocol used here (RFCOMM channel 8, packet format and command codes) comes from **[SaorCon](https://github.com/platinum95/SaorCon)** by **Peter Mullen** ([@platinum95](https://github.com/platinum95)), a QC35 control utility for Windows, specifically [release v0.0.1.0-alpha](https://github.com/platinum95/SaorCon/releases/tag/v0.0.1.0-alpha). SaorCon is released under the MIT License. This project is an independent macOS implementation and contains no code from SaorCon.

## Disclaimer

This project is not affiliated with, endorsed by, or supported by Bose Corporation. "Bose" and "QuietComfort" are trademarks of Bose Corporation. Use at your own risk.

## License

[MIT](LICENSE)
