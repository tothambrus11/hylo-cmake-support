# Research notes: C on ev3dev (Debian on microSD)

Collected 2026-08-22 from official docs/GitHub plus local verification in
Docker (`ev3dev/ev3dev-stretch-ev3-generic` rootfs, `ev3dev/debian-stretch-cross`).
Items marked **[verified]** were checked on this machine.

## 1. Status, images, flashing, brick setup

* Latest stable: **ev3dev-stretch R3** (`ev3dev-stretch-2020-04-10`, Debian 9.12,
  kernel `4.14.117-ev3dev-2.3.5-ev3` **[verified]**). No newer official EV3 image;
  buster was beta only; community Buster/Bullseye/Bookworm images exist but are
  unofficial (https://github.com/orgs/ev3dev/discussions/1636).
  Releases: https://github.com/ev3dev/ev3dev/releases – Downloads: https://www.ev3dev.org/downloads/
* Maintenance: dormant but alive (kernel repo pushed 2026-01, docker-cross 2024-06).
  Plan for stretch R3.
* SD card: microSD/microSDHC 2–32 GB (**no SDXC, nothing > 32 GB**). Flash with
  Etcher (docs say v1.17; `dd` of the unzipped `.img` works too). First boot 3–5 min.
  https://www.ev3dev.org/docs/getting-started/
* Network: USB cable (brick appears as CDC/RNDIS Ethernet gadget; on Linux create a
  NetworkManager connection "Shared to other computers"; brick gets 10.42.0.x),
  Bluetooth PAN tethering, USB Wi‑Fi dongle, USB Ethernet. Brick IP is shown at the
  top of the Brickman screen. https://www.ev3dev.org/docs/networking/
* SSH: `ssh robot@ev3dev.local`, password `maker` (robot has sudo). `scp prog robot@ev3dev.local:`.
  VS Code extension `ev3dev-browser` can deploy too.
* Running: from ssh prefer `brickrun -r ./prog` (console switching, stops motors on
  crash; Brickman uses it too). From Brickman's File Browser: file needs `chmod +x`
  (shown with `*`), a plain ARM ELF is fine, stdout goes to the LCD, stderr to
  `prog.err.log`. http://docs.ev3dev.org/en/ev3dev-stretch/programming/fundamentals.html

## 2. Cross-compiling

* Target: TI AM1808, ARM926EJ‑S (ARMv5TEJ, no FPU, 64 MB RAM), Debian **armel**
  (EABI soft-float). Stretch armel baseline is ARMv4T; glibc on brick = 2.24 **[verified]**.
* Official toolchain: Docker `ev3dev/debian-stretch-cross` (amd64 rootfs with
  `arm-linux-gnueabi-gcc 6.3` configured `--with-arch=armv4t --with-float=soft`,
  cmake 3.7, gdb-multiarch, qemu-user-static 2.8; user `compiler`, ships
  `/home/compiler/toolchain-armel.cmake`) **[verified]**.
  `docker run --rm -v "$PWD":/src -w /src ev3dev/debian-stretch-cross arm-linux-gnueabi-gcc -O2 -o prog prog.c`
  https://www.ev3dev.org/docs/tutorials/using-docker-to-cross-compile/ – https://github.com/ev3dev/docker-cross
* Ubuntu 24.04 `gcc-arm-linux-gnueabi` (gcc 13.3, `--with-arch=armv5t --with-float=soft`,
  cross glibc **2.39**) **[verified]**: dynamically linked binaries fail on the brick with
  `GLIBC_2.34 not found`; **link with `-static`** and they run fine in the stretch
  rootfs **[verified]**. Recommended flags:
  `-march=armv5te -mtune=arm926ej-s -mfloat-abi=soft -O2 -static`.
  Same conclusion: https://github.com/ev3dev/ev3dev/issues/1526
* clang: `--target=armv5te-linux-gnueabi -mfloat-abi=soft --sysroot=<stretch armel sysroot>`
  should work (Rust's `armv5te-unknown-linux-gnueabi` is LLVM-based and used for
  ev3dev) but no authoritative ev3dev doc confirms a clang+sysroot C setup.

## 3. sysfs API (stretch, kernel 4.14 / ev3dev-2.x)

Docs: sensors http://docs.ev3dev.org/projects/lego-linux-drivers/en/ev3dev-stretch/sensors.html,
motors http://docs.ev3dev.org/projects/lego-linux-drivers/en/ev3dev-stretch/motors.html,
catalogues `sensor_data.html` / `motor_data.html`, ports `ports.html`.

* Port names: stretch uses `ev3-ports:in1`…`in4`, `ev3-ports:outA`…`outD`
  (jessie used `in1`, `outA`). Always locate devices by reading `address`; `sensorN`/`motorN`
  numbering is unrelated to the port.
* Colour sensor `/sys/class/lego-sensor/sensorN/`: `address`, `driver_name`=`lego-ev3-color`,
  `modes`=`COL-REFLECT COL-AMBIENT COL-COLOR REF-RAW RGB-RAW COL-CAL`, write `COL-REFLECT`
  to `mode`; then `value0` is 0–100 (`units` pct, `decimals` 0, `num_values` 1).
* Large motor `/sys/class/tacho-motor/motorN/`: `address`, `driver_name`=`lego-ev3-l-motor`
  (medium `lego-ev3-m-motor`), `commands`=`run-forever run-to-abs-pos run-to-rel-pos run-timed
  run-direct stop reset` (write to `command`), `speed_sp` (tacho counts/s; negative = reverse),
  `max_speed` (large **1050**, medium 1560), `count_per_rot`=360, `duty_cycle_sp` (−100..100, with
  `run-direct`), `position` (r/w), `position_sp`, `time_sp`, `ramp_up_sp`/`ramp_down_sp`,
  `stop_action` ∈ `coast brake hold`, `polarity` ∈ `normal inversed`, `state` (`running ramping
  holding overloaded stalled`), `speed`.
* Buttons: evdev `/dev/input/by-path/platform-gpio_keys-event` (stretch); key codes
  UP 103, DOWN 108, LEFT 105, RIGHT 106, ENTER 28, BACK(SPACE) 14. 16-byte `struct input_event`.
* LEDs: `/sys/class/leds/led0:red:brick-status`, `led0:green:brick-status`, `led1:*` – `brightness` 0–255.
* C libraries: `in4lio/ev3dev-c` (MIT, still pushed 2026-07), `ddemidov/ev3dev-lang-cpp`
  (C++ bindings, 2022). ev3dev's own C tutorial just says to read/write the sysfs files:
  https://www.ev3dev.org/docs/tutorials/getting-started-with-c/

## 4. Permissions

No sudo needed: udev rule `60-ev3dev.rules` chowns `lego-sensor`, `tacho-motor`,
`leds` attributes to group `ev3dev`; `robot` is in `ev3dev input ...` **[verified]**.
Caveat: the chown is asynchronous, so writing within a few ms of hot-plugging a
device can EACCES (retry).

## 5. QEMU

* No full-system machine model for the AM1808 exists in upstream QEMU; the ev3dev
  maintainer recommends user-mode emulation. https://github.com/ev3dev/ev3dev/issues/52
* User mode (`qemu-arm-static`) is what ev3dev's own tooling uses (brickstrap,
  docker-library). `docker run --rm -it ev3dev/ev3dev-stretch-ev3-generic bash` is the
  exact R3 rootfs under qemu **[verified]** – good for smoke tests. Use `-cpu arm926`
  with qemu-arm to catch accidental ARMv6/v7 instructions.
