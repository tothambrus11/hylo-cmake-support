/* ev3c -- a deliberately tiny C API for the LEGO MINDSTORMS EV3.
 *
 * Scope: what a differential-drive line-following robot needs and nothing
 * more: one EV3 colour sensor (reflected light), two large motors, timing,
 * a "keep running?" flag and a little logging. Everything is an int so that
 * the API is trivial to call from Hylo through @extern_c_indirect (see
 * ev3c_hylo.c), which can only pass simple scalars today.
 *
 * Backends (pick at link time, see CMakeLists.txt):
 *   ev3c_sysfs.c  -- ev3dev (Debian on SD card). Talks to the kernel drivers
 *                    through sysfs: /sys/class/lego-sensor and
 *                    /sys/class/tacho-motor. Also used by the simulator: set
 *                    EV3C_SYSFS_ROOT=<dir> and the SAME binary reads/writes a
 *                    fake sysfs tree maintained by ev3/sim/ev3sim.py.
 *   ev3c_c4ev3.c  -- stock LEGO firmware (no SD card) via the C4EV3 EV3-API.
 *                    Not built here because it needs the C4EV3 toolchain;
 *                    it is a thin mapping, see ev3/docs/STOCK-FIRMWARE.md.
 *
 * All functions are safe to call in a 100 Hz control loop on the EV3's
 * 300 MHz ARM9.
 */
#ifndef EV3C_H
#define EV3C_H

#ifdef __cplusplus
extern "C" {
#endif

/* Sets everything up: finds the colour sensor (any input port, or the one
 * named in $EV3C_COLOR_PORT, e.g. "in1"), puts it in reflected-light mode,
 * finds the left/right large motors (ports $EV3C_LEFT_MOTOR / $EV3C_RIGHT_MOTOR,
 * default outB / outC), resets them, and installs SIGINT/SIGTERM handlers so
 * that Ctrl-C or the simulator stopping the program also stops the motors.
 * Returns 0 on success, -1 if a device is missing (a message is printed). */
int ev3c_init(void);

/* Stops the motors and releases resources. Safe to call more than once. */
void ev3c_shutdown(void);

/* 1 until SIGINT/SIGTERM arrives or the brick's BACK button is pressed. */
int ev3c_running(void);

/* Reflected light, 0 (black) .. 100 (white). -1 on read error. */
int ev3c_color_reflect(void);

/* Runs both motors continuously. Speeds are percent of the motor's maximum
 * speed, -100..100 (clamped). 0 = hold still. */
void ev3c_drive(int left_percent, int right_percent);

/* Stops both motors (brake). */
void ev3c_stop(void);

/* Tacho position of a motor in degrees since init. side: 0 = left, 1 = right. */
int ev3c_motor_position(int side);

/* Sleeps for `ms` milliseconds. */
void ev3c_sleep_ms(int ms);

/* Milliseconds elapsed since ev3c_init(). */
int ev3c_millis(void);

/* Prints "tag=value" on stdout (line buffered, so it shows up immediately over
 * ssh and in the simulator). `tag` is an arbitrary integer because Hylo cannot
 * hand us a C string yet. */
void ev3c_log(int tag, int value);

/* Reads an integer tuning parameter from the environment variable
 * EV3C_<name> (e.g. EV3C_KP), or returns `fallback`. Handy to tune the
 * controller without recompiling. */
int ev3c_param(const char* name, int fallback);

#ifdef __cplusplus
}
#endif
#endif /* EV3C_H */
