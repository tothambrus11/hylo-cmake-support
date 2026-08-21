# Research notes: native C on the stock LEGO firmware (no SD card) – C4EV3

Collected 2026-08-22. The stock firmware (1.09H/1.10E) is itself Linux
(kernel **2.6.33-rc4**, TI DaVinci PSP SDK) running the `lms2012` VM; native ARM
ELF binaries can be uploaded with the normal EV3 protocol and started from the
brick's menu. The ecosystem for that is **C4EV3** (https://c4ev3.github.io/).

## 1. Projects and status

| Repo | What | Status |
|---|---|---|
| https://github.com/c4ev3/EV3-API | C library `libev3api.a`: motors, sensors, LCD, buttons, sound, BT | last commit 2020-07; GPL-2 |
| https://github.com/c4ev3/ev3duder | host uploader/runner (USB HID, BT RFCOMM, Wi-Fi TCP) | last commit 2021-04 (Jakub Vaněk; his fork pushed 2025-06) |
| https://github.com/c4ev3/C4EV3.Toolchain | GCC 8.2.1 + **uclibc-ng, static**, kernel headers 2.6.33, `arm-c4ev3-linux-uclibceabi-` | release 2019.08.0 (linux-amd64 tarball) |
| https://github.com/c4ev3/Windows-Installer, EV3-Eclipse-Plugin | Windows installer (v2020.01) / Eclipse CDT | Windows only |

Dormant since ~2020–21 but functional; no open breakage issues. John Hansen's older
"EV3 C API" (BricxCC) is what EV3-API was merged from (abandoned).

## 2. Toolchain (important!)

* Target: ARM926EJ-S (ARMv5TEJ, soft-float EABI). Brick glibc ≈ **2.8** (firmware was
  built with CodeSourcery 2009q1 = GCC 4.3.3/glibc 2.8) and kernel **2.6.33**.
* Consequences:
  * Dynamically linking with a modern `arm-linux-gnueabi-gcc` fails on the brick
    (`GLIBC_2.xx not found`, EV3-API issue #10).
  * **Static linking with a modern glibc (Ubuntu 24.04 = 2.39) also fails**: Debian/Ubuntu
    glibc is built with `--enable-kernel=3.2`, the binary carries the note
    "for GNU/Linux 3.2.0" and aborts at start-up with `FATAL: kernel too old` on 2.6.33.
    (This is the gap the C4EV3.Toolchain was created to close.)
* Therefore use one of:
  1. **C4EV3.Toolchain 2019.08.0** (`arm-c4ev3-linux-uclibceabi-gcc`, uclibc-ng, static by
     default, built `--with-cpu=arm926ej-s`, kernel headers 2.6.33) – recommended, Linux x86-64.
     https://github.com/c4ev3/C4EV3.Toolchain/releases
  2. CodeSourcery Sourcery G++ Lite **2009q1-203 arm-none-linux-gnueabi** (GCC 4.3.3,
     glibc 2.8 – matches the brick, dynamic linking OK). Official download URL is dead;
     mirrors exist. Needs 32-bit host libs.
* EV3-API build: plain `make PREFIX=arm-c4ev3-linux-uclibceabi-` (Makefile uses
  `$(PREFIX)gcc`, `-std=c99 -Os -fno-strict-aliasing -fwrapv`), produces `libev3api.a`;
  link programs with `-L<EV3-API> -lev3api -lpthread` (`-static` if not default, `-Os`).

## 3. Upload & run (ev3duder)

Build ev3duder: `git clone --recursive https://github.com/c4ev3/ev3duder && sudo apt install
libudev-dev pkg-config && make && sudo make install` (installs udev rule, VID 0694 / PID 0005).

```
ev3duder [--usb | --tcp[=ip] | --serial[=dev]] up <local> <remote> | dl | rm | ls | mkdir |
         mkrbf <abs-brick-path-of-elf> <local.rbf> | run <remote.rbf> | exec <cmd> | info
```
* Remote paths for `up` are relative to `/home/root/lms2012/prjs/sys/`, so programs go to
  `../prjs/BrkProg_SAVE/<name>` (shows up in the brick's "Brick Program" tab). `../apps/`
  puts it in the Apps tab.
* Workflow:
  ```
  arm-c4ev3-linux-uclibceabi-gcc -Os main.c -I EV3-API/include -L EV3-API -lev3api -lpthread -o prog
  ev3duder up prog ../prjs/BrkProg_SAVE/prog
  ev3duder mkrbf /home/root/lms2012/prjs/BrkProg_SAVE/prog prog.rbf   # absolute brick path!
  ev3duder up prog.rbf ../prjs/BrkProg_SAVE/prog.rbf
  ev3duder run ../prjs/BrkProg_SAVE/prog.rbf        # or start it from the brick menu
  ```
* The `.rbf` is a 1-instruction bytecode program (`opSystem "<path>"`) – the VM runs your
  ELF via `system()` **as root**. No brick setup / developer mode needed.
* `ev3duder exec '/home/root/lms2012/prjs/BrkProg_SAVE/prog'` (USB only) streams the
  program's stdout/stderr back to your terminal. Started from the menu, stdout is invisible:
  use `LcdPrintf`/`TermPrintf`.

## 4. EV3-API cheat-sheet (current master, `#include <ev3.h>`)

* `InitEV3()` / `FreeEV3()`; `Wait(ms)`; `TimerGetMS()`.
* Sensors: `SetAllSensors(EV3Color, NULL, NULL, NULL)` (handlers: `EV3Color, EV3Touch,
  EV3Ultrasonic, EV3Gyro, EV3Ir, ...`), `int ReadEV3ColorSensorReflectedLight(IN_1)` (0–100),
  `ReadEV3ColorSensorAmbientLight`, `ReadEV3ColorSensorColor`. Ports `IN_1..IN_4` = 0..3.
  Colour/gyro/US are UART sensors: a mode change costs ~200 ms.
* Motors: `OnFwdReg(OUT_BC, speed)` (speed −100..100, regulated), `OnFwdRegEx(outs, speed,
  OUT_REGMODE_SPEED, RESET_NONE)`, `OnFwdSyncEx(outs, speed, turn, reset)`, `Off(outs)`
  (brake), `Float(outs)`, `OutputSpeed/OutputPower/OutputStart/OutputStop`,
  `MotorRotationCount(OUT_B)`, `ResetRotationCount`. Ports are bitmasks: `OUT_A 1, OUT_B 2,
  OUT_C 4, OUT_D 8, OUT_BC 6`.
* Buttons: `ButtonIsDown(BTNEXIT)` (also `BTNCENTER, BTNUP, ...`), LEDs `SetLedPattern(LED_GREEN)`.
* LCD: `LcdClean()`, `LcdTextf(1, x, LcdRowToY(row), "fmt", ...)`, `LcdPrintf`, `TermPrintf`.
* Uses `/dev/lms_pwm, lms_motor, lms_uart, lms_analog, lms_ui, fb0` – only on the stock kernel.

## 5. Alternatives
* Telnet: disabled since firmware 1.09; LEGO's "Firmware Developer Edition 1.09D" has
  telnet (root). Not needed with ev3duder.
* **EV3RT** (TOPPERS RTOS, `gcc-arm-none-eabi`, HRP3 1.1 2021, pybricks fork 2024): great
  real-time C, but boots from a microSD card (stock flash untouched).
* ev3dev: SD card, full Debian – see research-ev3dev.md.
