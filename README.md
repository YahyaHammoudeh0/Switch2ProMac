# Switch 2 Pro Controller for Steam on macOS

Enables the Nintendo Switch 2 Pro Controller (and the NSO GameCube controller) over USB in Steam on macOS. The controller then shows up in Steam's controller settings and works in games through Steam Input.

> This is a fork of [dannydarvish/Switch2ProMac](https://github.com/dannydarvish/Switch2ProMac). All credit for the original initialization script goes to **Danny Darvish**, whose work is in turn based on **ikz87**'s [NSW2-controller-enabler](https://github.com/ikz87/NSW2-controller-enabler) for Linux. This fork adds automatic initialization, a fix for macOS 27, and a HID scanning tool.

## What this fork adds

- **Automatic setup on plug-in.** A small LaunchAgent watches for the controller and runs `pro2steam.sh` every time it's connected, so you never run the script by hand.
- **macOS 27 fix.** On macOS 27 the controller stopped appearing in Steam even after initialization. Steam's log showed the device being found but never opened. The cause: macOS's GameController framework now *claims* the controller (`GCController.supportsHIDDevice` returns true) but never creates a usable `GCController` for it, and SDL (which Steam uses) skips any device the framework claims. Setting `SDL_JOYSTICK_MFI=0` for the login session makes SDL read the controller through IOKit instead, and Steam picks it up again. The watcher sets this automatically.
- **`controller_scan.py`**, a live HID scanner for reverse-engineering the controller's report layout (stick bytes, ranges, calibration).
- `pro2steam.sh` no longer launches Steam itself; it only initializes the controller.

## Setup

```bash
git clone https://github.com/YahyaHammoudeh0/Switch2ProMac.git
cd Switch2ProMac
bash pro2steam.sh        # first run creates a venv and installs pyusb + hidapi
./install-agent.sh       # start the watcher now and at every login
```

Then plug in the controller over USB and open Steam → Settings → Controller. The first time, also allow Steam under System Settings → Privacy & Security → Input Monitoring.

Launch Steam *after* logging in (not before the agent runs) so it inherits `SDL_JOYSTICK_MFI=0`. If the controller is missing, quit and reopen Steam.

Log: `~/Library/Logs/Switch2ProMac.log`. To remove the agent: `./install-agent.sh uninstall`.

Optional machine-specific extras (for example other `launchctl setenv` calls) can go in `local-env.sh`, which the watcher sources if present. It's ignored by git.

## Manual use

```bash
bash pro2steam.sh
```

## Known limitations

- USB only.
- GameHub for Mac (beta 0.8.613) doesn't support this controller yet; its gamepad service logs `unsupported gamepad device parser vendor_id=057e product_id=2069`.

## Acknowledgments

- [Danny Darvish](https://github.com/dannydarvish), for the original [Switch2ProMac](https://github.com/dannydarvish/Switch2ProMac) script this fork builds on.
- [ikz87](https://github.com/ikz87), for the [Linux script](https://github.com/ikz87/NSW2-controller-enabler) that reverse-engineered the initialization sequence.
