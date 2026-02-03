#!/bin/bash
#
# pro2steam.sh - NS2 Pro Controller Steam Launcher (All-in-One)
#
# This script sets up the environment and launches Steam with NS2 controller support.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"

echo "=== NS2 Pro Controller - Steam Launcher ==="

# Step 1: Check/create virtual environment
if [ ! -d "$VENV_DIR" ]; then
    echo ""
    echo "[1/4] Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
    echo "Virtual environment created."

    echo ""
    echo "[2/4] Installing dependencies..."
    source "$VENV_DIR/bin/activate"
    pip install --quiet pyusb hidapi
    echo "Dependencies installed."
else
    echo ""
    echo "[1/4] Virtual environment found."
    echo "[2/4] Dependencies already installed."
    source "$VENV_DIR/bin/activate"
fi

# Step 3: Initialize controller
echo ""
echo "[3/4] Initializing controller..."

python3 << 'PYTHON_EOF'
import sys
import time
from typing import Optional

try:
    import usb.core
    import usb.util
except ImportError:
    sys.exit("Missing pyusb. Install with: pip3 install pyusb")

try:
    import hid
except ImportError:
    sys.exit("Missing hidapi. Install with: pip3 install hidapi")


class NS2ControllerInitializer:
    """
    Handles USB communication to initialize the NS2 Pro Controller,
    switching it into standard HID mode.
    """

    # Device identifiers
    VENDOR_ID = 0x057E   # Nintendo
    PRODUCT_ID = 0x2069  # NS2 Pro Controller
    PRODUCT_ID_ALT = 0x2073  # NSO GameCube Controller (alternate)
    USB_INTERFACE = 1

    # Initialization command sequence (from reverse engineering)
    COMMANDS = [
        bytes([0x03, 0x91, 0x00, 0x0D, 0x00, 0x08, 0x00, 0x00, 0x01, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        bytes([0x07, 0x91, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]),
        bytes([0x16, 0x91, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]),
        bytes([0x15, 0x91, 0x00, 0x01, 0x00, 0x0E, 0x00, 0x00, 0x00, 0x02, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        bytes([0x15, 0x91, 0x00, 0x02, 0x00, 0x11, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        bytes([0x15, 0x91, 0x00, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00]),
        bytes([0x09, 0x91, 0x00, 0x07, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
        bytes([0x0C, 0x91, 0x00, 0x02, 0x00, 0x04, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00]),
        bytes([0x11, 0x91, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00]),
        bytes([0x0A, 0x91, 0x00, 0x08, 0x00, 0x14, 0x00, 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x35, 0x00, 0x46, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
        bytes([0x0C, 0x91, 0x00, 0x04, 0x00, 0x04, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00]),
        bytes([0x03, 0x91, 0x00, 0x0A, 0x00, 0x04, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00]),
        bytes([0x10, 0x91, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]),
        bytes([0x01, 0x91, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x00]),
        bytes([0x03, 0x91, 0x00, 0x01, 0x00, 0x00, 0x00]),
        bytes([0x0A, 0x91, 0x00, 0x02, 0x00, 0x04, 0x00, 0x00, 0x03, 0x00, 0x00]),
        bytes([0x09, 0x91, 0x00, 0x07, 0x00, 0x08, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),  # Set player LED
    ]

    def __init__(self):
        self.device: Optional[usb.core.Device] = None
        self.endpoint_out: Optional[int] = None
        self.endpoint_in: Optional[int] = None
        self.active_pid: int = 0

    def find_device(self) -> bool:
        """Find the NS2 Pro Controller via USB."""
        # Try primary PID first
        self.device = usb.core.find(
            idVendor=self.VENDOR_ID,
            idProduct=self.PRODUCT_ID
        )
        if self.device:
            self.active_pid = self.PRODUCT_ID
            return True

        # Try alternate PID
        self.device = usb.core.find(
            idVendor=self.VENDOR_ID,
            idProduct=self.PRODUCT_ID_ALT
        )
        if self.device:
            self.active_pid = self.PRODUCT_ID_ALT
            return True

        return False

    def connect(self) -> bool:
        """Connect to the controller and set up endpoints."""
        if not self.device:
            return False

        try:
            # On macOS, we don't need to detach kernel drivers the same way
            # Just set the configuration and claim the interface
            try:
                self.device.set_configuration()
            except usb.core.USBError:
                # Configuration may already be set
                pass

            config = self.device.get_active_configuration()
            interface = config[(self.USB_INTERFACE, 0)]

            # Find bulk endpoints
            for endpoint in interface:
                direction = usb.util.endpoint_direction(endpoint.bEndpointAddress)
                if direction == usb.util.ENDPOINT_OUT:
                    self.endpoint_out = endpoint.bEndpointAddress
                elif direction == usb.util.ENDPOINT_IN:
                    self.endpoint_in = endpoint.bEndpointAddress

            if not self.endpoint_out:
                print("Error: Could not find bulk OUT endpoint", file=sys.stderr)
                return False

            return True

        except usb.core.USBError as e:
            print(f"USB connection error: {e}", file=sys.stderr)
            print("\nIf you see 'Access denied', try:", file=sys.stderr)
            print("  1. Run with sudo: sudo python3 ns2_macos_init.py", file=sys.stderr)
            print("  2. Or grant terminal USB access in System Settings > Privacy & Security", file=sys.stderr)
            return False

    def send_command(self, data: bytes) -> bool:
        """Send a command and optionally read response."""
        if not self.device or not self.endpoint_out:
            return False

        try:
            self.device.write(self.endpoint_out, data, timeout=1000)

            # Try to read response if we have an IN endpoint
            if self.endpoint_in:
                try:
                    time.sleep(0.01)
                    self.device.read(self.endpoint_in, 64, timeout=100)
                except usb.core.USBTimeoutError:
                    pass  # No response is OK

            return True

        except usb.core.USBError as e:
            print(f"USB write error: {e}", file=sys.stderr)
            return False

    def initialize(self) -> bool:
        """Send the full initialization sequence."""
        print("Sending initialization commands...")

        for i, command in enumerate(self.COMMANDS):
            if not self.send_command(command):
                print(f"Failed at command {i + 1}/{len(self.COMMANDS)}", file=sys.stderr)
                return False
            time.sleep(0.05)

        print(f"Sent {len(self.COMMANDS)} commands successfully")
        return True

    def disconnect(self):
        """Clean up USB connection."""
        if self.device:
            try:
                usb.util.release_interface(self.device, self.USB_INTERFACE)
                usb.util.dispose_resources(self.device)
            except Exception:
                pass
            self.device = None


def check_hid_device(vendor_id: int, product_id: int) -> bool:
    """Check if the controller appears as an HID device."""
    try:
        devices = hid.enumerate(vendor_id, product_id)
        return len(devices) > 0
    except Exception:
        return False


def read_hid_test(vendor_id: int, product_id: int, duration: float = 5.0):
    """Test reading HID reports from the controller."""
    print(f"\nAttempting to read HID data for {duration} seconds...")
    print("Press buttons on the controller to see if data changes.\n")

    try:
        h = hid.device()
        h.open(vendor_id, product_id)
        h.set_nonblocking(True)

        start_time = time.time()
        report_count = 0
        last_report = None

        while time.time() - start_time < duration:
            report = h.read(64)
            if report:
                report_count += 1
                # Only print if data changed (to reduce spam)
                if report != last_report:
                    # Show first 20 bytes in hex
                    hex_data = ' '.join(f'{b:02X}' for b in report[:20])
                    print(f"Report #{report_count}: {hex_data}...")
                    last_report = report
            time.sleep(0.01)

        h.close()
        print(f"\nReceived {report_count} HID reports")
        return report_count > 0

    except IOError as e:
        print(f"Could not open HID device: {e}", file=sys.stderr)
        return False


def main():
    print("=" * 60)
    print("NS2 Pro Controller - macOS Initializer")
    print("=" * 60)

    initializer = NS2ControllerInitializer()

    # Step 1: Find the controller
    print("\n[1/4] Searching for NS2 Pro Controller...")
    if not initializer.find_device():
        print("Controller not found!", file=sys.stderr)
        print("\nMake sure the controller is:")
        print("  - Connected via USB cable")
        print("  - Powered on")
        print(f"\nLooking for VID:0x{NS2ControllerInitializer.VENDOR_ID:04X} "
              f"PID:0x{NS2ControllerInitializer.PRODUCT_ID:04X} or "
              f"0x{NS2ControllerInitializer.PRODUCT_ID_ALT:04X}")

        # List all Nintendo devices for debugging
        print("\nSearching for any Nintendo USB devices...")
        for dev in usb.core.find(find_all=True, idVendor=0x057E):
            print(f"  Found: VID:0x{dev.idVendor:04X} PID:0x{dev.idProduct:04X}")

        sys.exit(1)

    print(f"Found controller: VID:0x{initializer.device.idVendor:04X} "
          f"PID:0x{initializer.device.idProduct:04X}")

    # Check if it's already in HID mode before initialization
    print("\nChecking if controller is already in HID mode...")
    if check_hid_device(NS2ControllerInitializer.VENDOR_ID, initializer.active_pid):
        print("Controller already appears as HID device!")
        print("Testing if it sends data without initialization...")
        if read_hid_test(NS2ControllerInitializer.VENDOR_ID, initializer.active_pid, duration=3.0):
            print("\nController is already working! Skipping initialization.")
            sys.exit(0)

    # Step 2: Connect
    print("\n[2/4] Connecting to USB interface...")
    if not initializer.connect():
        sys.exit(1)
    print("Connected!")

    # Step 3: Initialize
    print("\n[3/4] Initializing controller...")
    if not initializer.initialize():
        initializer.disconnect()
        sys.exit(1)
    print("Initialization complete!")

    # Save PID before disconnect
    active_pid = initializer.active_pid

    # Disconnect USB to let HID take over
    initializer.disconnect()

    # Step 4: Verify HID mode
    print("\n[4/4] Waiting for HID device...")
    time.sleep(2)

    if check_hid_device(NS2ControllerInitializer.VENDOR_ID, active_pid):
        print("Controller is now in HID mode!")

        # Test reading data
        read_hid_test(NS2ControllerInitializer.VENDOR_ID, active_pid)

        print("\n" + "=" * 60)
        print("SUCCESS! The controller should now be visible to Steam.")
        print("=" * 60)
        print("\nNext steps:")
        print("  1. Open Steam")
        print("  2. Go to Steam > Settings > Controller")
        print("  3. Check if the controller appears")
        print("  4. If not, try Steam > Settings > Controller > General Controller Settings")
    else:
        print("Warning: HID device not detected after initialization", file=sys.stderr)
        print("The controller may need additional setup.", file=sys.stderr)


if __name__ == "__main__":
    main()
PYTHON_EOF

if [ $? -ne 0 ]; then
    echo "Warning: Controller initialization may have failed"
    echo "Continuing anyway..."
fi

# Step 4: Set SDL mapping and launch Steam
echo ""
echo "[4/4] Launching Steam..."

export SDL_GAMECONTROLLERCONFIG="030000007e0500006920000001000000,Nintendo Switch 2 Pro Controller,a:b1,b:b0,x:b3,y:b2,back:b8,guide:b12,start:b9,leftstick:b10,rightstick:b11,leftshoulder:b4,rightshoulder:b5,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,leftx:a0,lefty:a1,rightx:a2,righty:a3,lefttrigger:b6,righttrigger:b7,paddle1:b18,paddle2:b19,platform:Mac OS X,"

/Applications/Steam.app/Contents/MacOS/steam_osx >/dev/null 2>&1 &
disown
echo "Steam launched in background. You can close this terminal."
