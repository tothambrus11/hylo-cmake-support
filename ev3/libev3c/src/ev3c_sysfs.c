/* ev3c backend for ev3dev (Debian on the EV3, https://www.ev3dev.org).
 *
 * ev3dev exposes every sensor and motor as a directory of small text files
 * ("attributes") under /sys/class/lego-sensor and /sys/class/tacho-motor.
 * Reading a sensor is reading a file; running a motor is writing two files.
 * There is no library to link, no daemon, nothing to install on the brick.
 * See ev3/docs/research-ev3dev.md for the attribute names and their meaning.
 *
 * Simulation: if $EV3C_SYSFS_ROOT is set it replaces "/sys". The simulator
 * (ev3/sim/ev3sim.py) maintains an identical directory tree with the same
 * files, so this backend -- and the binary built from it -- is exactly what
 * runs on the brick. Files are re-opened on every access on purpose: sysfs
 * attributes must be re-read anyway, and this makes the behaviour identical
 * whether a kernel or a Python script is on the other side.
 */
#define _GNU_SOURCE
#include "ev3c.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* ------------------------------------------------------------------ config */

#define EV3C_PATH_MAX 256   /* device directory */
#define EV3C_ATTR_MAX 384   /* device directory + attribute name */

static const char* sysfs_root(void) {
  const char* r = getenv("EV3C_SYSFS_ROOT");
  return (r && *r) ? r : "/sys";
}

/* -------------------------------------------------------- file primitives */

/* Reads a whole attribute file into buf (NUL-terminated, trailing newline
 * stripped). Returns length or -1. */
static int read_attr(const char* path, char* buf, int cap) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return -1;
  int n = 0;
  for (;;) {
    int r = (int)read(fd, buf + n, (size_t)(cap - 1 - n));
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) break;
    n += r;
    if (n >= cap - 1) break;
  }
  close(fd);
  while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == ' ')) n--;
  buf[n] = 0;
  return n;
}

static int write_attr(const char* path, const char* value) {
  int fd = open(path, O_WRONLY | O_TRUNC);
  if (fd < 0) return -1;
  size_t len = strlen(value);
  int ok = write(fd, value, len) == (ssize_t)len;
  close(fd);
  return ok ? 0 : -1;
}

static int read_attr_int(const char* path, int fallback) {
  char buf[64];
  /* A simulator writing the file in place may be caught mid-write once in a
   * blue moon; an empty read is retried once before giving up. */
  for (int attempt = 0; attempt < 2; attempt++) {
    if (read_attr(path, buf, sizeof buf) > 0) {
      char* end;
      long v = strtol(buf, &end, 10);
      if (end != buf) return (int)v;
    }
  }
  return fallback;
}

/* out = dir "/" name. dir is at most EV3C_PATH_MAX-1 long and name is a short
 * attribute name, so EV3C_ATTR_MAX always suffices; GCC cannot see that. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wformat-truncation"
static void join(char* out, const char* dir, const char* name) {
  snprintf(out, EV3C_ATTR_MAX, "%s/%s", dir, name);
}
#pragma GCC diagnostic pop

/* Does `address` (e.g. "ev3-ports:outB" on stretch, "outB" on jessie) refer to
 * port `port` (e.g. "outB")? */
static int address_is_port(const char* address, const char* port) {
  size_t la = strlen(address), lp = strlen(port);
  if (la < lp) return 0;
  if (strcmp(address + la - lp, port) != 0) return 0;
  return la == lp || address[la - lp - 1] == ':';
}

/* Finds the first device directory under <root>/class/<class>/ whose
 * `driver_name` equals `driver` (if non-NULL) and whose `address` is `port`
 * (if non-NULL). Returns 0 and fills `out` on success. */
static int find_device(const char* cls, const char* driver, const char* port, char* out) {
  char dir[EV3C_PATH_MAX];
  snprintf(dir, sizeof dir, "%s/class/%s", sysfs_root(), cls);
  DIR* d = opendir(dir);
  if (!d) return -1;
  struct dirent* e;
  int found = -1;
  while (found != 0 && (e = readdir(d)) != NULL) {
    if (e->d_name[0] == '.') continue;
    char dev[EV3C_PATH_MAX], attr[EV3C_ATTR_MAX], val[128];
    if (snprintf(dev, sizeof dev, "%s/%s", dir, e->d_name) >= (int)sizeof dev) continue;
    if (driver) {
      join(attr, dev, "driver_name");
      if (read_attr(attr, val, sizeof val) < 0 || strcmp(val, driver) != 0) continue;
    }
    if (port) {
      join(attr, dev, "address");
      if (read_attr(attr, val, sizeof val) < 0 || !address_is_port(val, port)) continue;
    }
    strncpy(out, dev, EV3C_PATH_MAX - 1);
    out[EV3C_PATH_MAX - 1] = 0;
    found = 0;
  }
  closedir(d);
  return found;
}

/* ------------------------------------------------------------------ state */

static char g_sensor[EV3C_PATH_MAX];
static char g_motor[2][EV3C_PATH_MAX];
static int g_max_speed[2] = {1050, 1050};
static int g_last_speed[2] = {1 << 30, 1 << 30}; /* "never written" */
static struct timespec g_t0;
static int g_buttons_fd = -1;
static volatile sig_atomic_t g_stop = 0;
static int g_initialized = 0;

static void on_signal(int sig) {
  (void)sig;
  g_stop = 1;
}

/* ------------------------------------------------------------------- init */

static const char* env_or(const char* name, const char* fallback) {
  const char* v = getenv(name);
  return (v && *v) ? v : fallback;
}

int ev3c_init(void) {
  char attr[EV3C_ATTR_MAX];

  /* Line-buffer stdout so logs are visible immediately over ssh / in the
   * simulator's pipe; Brickman shows stdout on the LCD. */
  setvbuf(stdout, NULL, _IOLBF, 0);

  const char* color_port = getenv("EV3C_COLOR_PORT"); /* NULL = any port */
  if (color_port && !*color_port) color_port = NULL;
  if (find_device("lego-sensor", "lego-ev3-color", color_port, g_sensor) != 0) {
    fprintf(stderr, "ev3c: no EV3 colour sensor found under %s/class/lego-sensor"
            " (is it plugged in? port filter: %s)\n", sysfs_root(), color_port ? color_port : "any");
    return -1;
  }
  join(attr, g_sensor, "mode");
  if (write_attr(attr, "COL-REFLECT") != 0) {
    fprintf(stderr, "ev3c: cannot set sensor mode (%s): %s\n", attr, strerror(errno));
    return -1;
  }

  const char* ports[2] = {env_or("EV3C_LEFT_MOTOR", "outB"), env_or("EV3C_RIGHT_MOTOR", "outC")};
  for (int i = 0; i < 2; i++) {
    if (find_device("tacho-motor", NULL, ports[i], g_motor[i]) != 0) {
      fprintf(stderr, "ev3c: no motor on port %s under %s/class/tacho-motor\n", ports[i], sysfs_root());
      return -1;
    }
    join(attr, g_motor[i], "max_speed");
    g_max_speed[i] = read_attr_int(attr, 1050);
    join(attr, g_motor[i], "command");
    write_attr(attr, "reset"); /* stop + zero position + default settings */
    join(attr, g_motor[i], "stop_action");
    write_attr(attr, "brake");
    g_last_speed[i] = 1 << 30;
  }

  /* BACK button (evdev). Optional: absent in the simulator. */
  const char* btn = env_or("EV3C_BUTTONS_DEV", "/dev/input/by-path/platform-gpio_keys-event");
  g_buttons_fd = open(btn, O_RDONLY | O_NONBLOCK);

  signal(SIGINT, on_signal);
  signal(SIGTERM, on_signal);
  clock_gettime(CLOCK_MONOTONIC, &g_t0);
  g_stop = 0;
  g_initialized = 1;
  printf("ev3c: sensor %s, left %s (max %d), right %s (max %d)\n", g_sensor, g_motor[0],
         g_max_speed[0], g_motor[1], g_max_speed[1]);
  return 0;
}

void ev3c_shutdown(void) {
  if (!g_initialized) return;
  ev3c_stop();
  if (g_buttons_fd >= 0) close(g_buttons_fd);
  g_buttons_fd = -1;
  g_initialized = 0;
}

/* --------------------------------------------------------------- running */

int ev3c_running(void) {
  if (g_stop) return 0;
  if (g_buttons_fd >= 0) {
    /* struct input_event: time (2 x long), u16 type, u16 code, s32 value. */
    unsigned char ev[sizeof(long) * 2 + 8];
    while (read(g_buttons_fd, ev, sizeof ev) == (ssize_t)sizeof ev) {
      unsigned type = ev[sizeof(long) * 2] | (ev[sizeof(long) * 2 + 1] << 8);
      unsigned code = ev[sizeof(long) * 2 + 2] | (ev[sizeof(long) * 2 + 3] << 8);
      int value = ev[sizeof(long) * 2 + 4];
      if (type == 1 /*EV_KEY*/ && code == 14 /*KEY_BACKSPACE = BACK*/ && value == 1) g_stop = 1;
    }
  }
  return !g_stop;
}

/* ---------------------------------------------------------------- sensor */

int ev3c_color_reflect(void) {
  char attr[EV3C_ATTR_MAX];
  join(attr, g_sensor, "value0");
  return read_attr_int(attr, -1);
}

/* ---------------------------------------------------------------- motors */

static int clamp(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

static void motor_run(int i, int percent) {
  char attr[EV3C_ATTR_MAX], val[32];
  int sp = clamp(percent, -100, 100) * g_max_speed[i] / 100;
  if (sp == g_last_speed[i]) return; /* nothing changed: spare the sysfs writes */
  g_last_speed[i] = sp;
  snprintf(val, sizeof val, "%d", sp);
  join(attr, g_motor[i], "speed_sp");
  write_attr(attr, val);
  /* In ev3dev a new speed_sp only takes effect when the command is (re)issued. */
  join(attr, g_motor[i], "command");
  write_attr(attr, "run-forever");
}

void ev3c_drive(int left_percent, int right_percent) {
  motor_run(0, left_percent);
  motor_run(1, right_percent);
}

void ev3c_stop(void) {
  char attr[EV3C_ATTR_MAX];
  for (int i = 0; i < 2; i++) {
    join(attr, g_motor[i], "command");
    write_attr(attr, "stop");
    g_last_speed[i] = 1 << 30;
  }
}

int ev3c_motor_position(int side) {
  char attr[EV3C_ATTR_MAX];
  join(attr, g_motor[side ? 1 : 0], "position");
  return read_attr_int(attr, 0);
}

/* ------------------------------------------------------------------ misc */

void ev3c_sleep_ms(int ms) {
  if (ms <= 0) return;
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  while (nanosleep(&ts, &ts) != 0 && errno == EINTR && !g_stop) {}
}

int ev3c_millis(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (int)((now.tv_sec - g_t0.tv_sec) * 1000 + (now.tv_nsec - g_t0.tv_nsec) / 1000000);
}

void ev3c_log(int tag, int value) { printf("%d=%d\n", tag, value); }

int ev3c_param(const char* name, int fallback) {
  char var[64];
  snprintf(var, sizeof var, "EV3C_%s", name);
  const char* v = getenv(var);
  if (!v || !*v) return fallback;
  char* end;
  long r = strtol(v, &end, 10);
  return end == v ? fallback : (int)r;
}
