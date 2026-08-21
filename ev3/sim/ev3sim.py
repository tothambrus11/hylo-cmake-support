#!/usr/bin/env python3
"""ev3sim -- a small world simulator for an EV3 line-following robot.

The robot program is NOT linked against a simulation library: it is the very
same binary that runs on the brick (ev3dev), talking to a fake *sysfs* tree that
this script maintains:

    <root>/class/lego-sensor/sensor0/{address,driver_name,mode,value0,...}
    <root>/class/tacho-motor/motor0/{address,command,speed_sp,position,...}   (outB)
    <root>/class/tacho-motor/motor1/...                                        (outC)

ev3c (ev3/libev3c) reads and writes those files exactly like it reads and
writes /sys on ev3dev; the only difference is the EV3C_SYSFS_ROOT environment
variable. Run the program natively for quick iteration, or -- faithfully --
as the ARMv5 binary under qemu-arm (user mode) with `--runner qemu-arm-static`.

World: a closed black line on a white floor. Robot: differential drive, two
large motors, one colour sensor in reflected-light mode mounted ahead of the
axle. Physics: first-order motor speed response, exact differential-drive
kinematics, sensor = weighted blend of black/white over a small circular spot,
plus noise. The loop runs in real time (the program's sleeps are real).

    ev3sim.py --robot build/linefollower --duration 40 --svg run.svg
    ev3sim.py --robot build-ev3/linefollower --runner qemu-arm-static -- -cpu arm926

Exit status 0 = the robot completed the requested laps without losing the line.
"""
import argparse
import math
import os
import random
import shutil
import signal
import subprocess
import sys
import tempfile
import time

# ----------------------------------------------------------------- geometry

class Track:
    """A closed track built from a Catmull-Rom spline through control points.
    Lengths are centimetres. Provides distance-to-centreline queries through a
    uniform grid of segment buckets (pure Python, fast enough at 200 Hz)."""

    def __init__(self, points, width=2.0, samples_per_segment=24, cell=10.0):
        self.width = width
        self.poly = self._catmull_rom(points, samples_per_segment)
        self.n = len(self.poly)
        # cumulative arc length at each vertex, and total length
        self.cum = [0.0]
        for i in range(1, self.n + 1):
            a, b = self.poly[i - 1], self.poly[i % self.n]
            self.cum.append(self.cum[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
        self.length = self.cum[-1]
        self.cell = cell
        self.grid = {}
        for i in range(self.n):
            a, b = self.poly[i], self.poly[(i + 1) % self.n]
            x0, x1 = sorted((a[0], b[0]))
            y0, y1 = sorted((a[1], b[1]))
            pad = width + 4.0  # a sensor spot can only "see" this far from the segment
            for cx in range(int((x0 - pad) // cell), int((x1 + pad) // cell) + 1):
                for cy in range(int((y0 - pad) // cell), int((y1 + pad) // cell) + 1):
                    self.grid.setdefault((cx, cy), []).append(i)
        xs = [p[0] for p in self.poly]
        ys = [p[1] for p in self.poly]
        self.bbox = (min(xs), min(ys), max(xs), max(ys))

    @staticmethod
    def _catmull_rom(pts, k):
        out = []
        n = len(pts)
        for i in range(n):
            p0, p1, p2, p3 = pts[(i - 1) % n], pts[i], pts[(i + 1) % n], pts[(i + 2) % n]
            for j in range(k):
                t = j / k
                t2, t3 = t * t, t * t * t
                x = 0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * t + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2
                           + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3)
                y = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2
                           + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
                out.append((x, y))
        return out

    def nearest(self, x, y):
        """Returns (distance to centreline, arc-length position s, signed side).
        side > 0 means the point is on the left of the travel direction."""
        best = (float("inf"), 0.0, 0.0)
        key = (int(x // self.cell), int(y // self.cell))
        for i in self.grid.get(key, ()):
            ax, ay = self.poly[i]
            bx, by = self.poly[(i + 1) % self.n]
            dx, dy = bx - ax, by - ay
            l2 = dx * dx + dy * dy
            t = 0.0 if l2 == 0 else max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / l2))
            px, py = ax + t * dx, ay + t * dy
            d = math.hypot(x - px, y - py)
            if d < best[0]:
                cross = dx * (y - ay) - dy * (x - ax)
                best = (d, self.cum[i] + t * math.sqrt(l2), 1.0 if cross > 0 else -1.0)
        return best

    def pose_at(self, s):
        """(x, y, heading) at arc length s."""
        s %= self.length
        lo, hi = 0, self.n
        while lo < hi - 1:
            mid = (lo + hi) // 2
            if self.cum[mid] <= s:
                lo = mid
            else:
                hi = mid
        a, b = self.poly[lo], self.poly[(lo + 1) % self.n]
        seg = self.cum[lo + 1] - self.cum[lo]
        t = 0.0 if seg == 0 else (s - self.cum[lo]) / seg
        return a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]), math.atan2(b[1] - a[1], b[0] - a[0])


TRACKS = {
    # counter-clockwise loops; the robot follows the left edge of the line
    "oval": [(0, 0), (60, -15), (120, 0), (140, 30), (120, 60), (60, 75), (0, 60), (-20, 30)],
    "kidney": [(0, 0), (50, -10), (100, 10), (140, 0), (170, 30), (150, 70), (100, 60),
               (60, 80), (10, 70), (-20, 35)],
    "wiggle": [(0, 0), (40, -12), (80, 8), (120, -10), (160, 5), (190, 40), (160, 75),
               (120, 60), (80, 85), (40, 65), (0, 80), (-25, 40)],
}

# -------------------------------------------------------------- fake sysfs

class FakeSysfs:
    """The ev3dev sysfs subset ev3c uses, as real files in a scratch directory."""

    def __init__(self, root):
        self.root = root
        self.sensor = os.path.join(root, "class", "lego-sensor", "sensor0")
        self.motors = [os.path.join(root, "class", "tacho-motor", "motor%d" % i) for i in range(2)]
        os.makedirs(self.sensor)
        for m in self.motors:
            os.makedirs(m)
        self._init_files(self.sensor, {
            "address": "ev3-ports:in1", "driver_name": "lego-ev3-color",
            "modes": "COL-REFLECT COL-AMBIENT COL-COLOR REF-RAW RGB-RAW COL-CAL",
            "mode": "COL-REFLECT", "num_values": "1", "decimals": "0", "units": "pct",
            "value0": "0", "poll_ms": "0", "fw_version": "sim",
        })
        for m, port in zip(self.motors, ("outB", "outC")):
            self._init_files(m, {
                "address": "ev3-ports:" + port, "driver_name": "lego-ev3-l-motor",
                "commands": "run-forever run-to-abs-pos run-to-rel-pos run-timed run-direct stop reset",
                "command": "", "speed_sp": "0", "duty_cycle_sp": "0", "duty_cycle": "0",
                "position": "0", "position_sp": "0", "speed": "0", "max_speed": "1050",
                "count_per_rot": "360", "state": "", "stop_action": "coast",
                "stop_actions": "coast brake hold", "polarity": "normal", "time_sp": "0",
                "ramp_up_sp": "0", "ramp_down_sp": "0",
            })
        self._cmd_mtime = [None, None]
        self._speed_sp = [0, 0]

    @staticmethod
    def _init_files(d, attrs):
        for k, v in attrs.items():
            with open(os.path.join(d, k), "w") as f:
                f.write(v + "\n")

    @staticmethod
    def _read(path):
        try:
            with open(path) as f:
                return f.read().strip()
        except OSError:
            return ""

    @staticmethod
    def _write(path, value):
        # Atomic replace: the robot re-opens attributes on every access (like it
        # must with real sysfs), so it always sees a complete old or new value,
        # never an empty file mid-write.
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            f.write(str(value) + "\n")
        os.replace(tmp, path)

    def set_sensor(self, value):
        self._write(os.path.join(self.sensor, "value0"), int(value))

    def sensor_mode(self):
        return self._read(os.path.join(self.sensor, "mode"))

    def poll_motor(self, i):
        """Returns (command_event or None, speed_sp, stop_action). A command is an
        event whenever the `command` file was written (mtime changed), exactly
        like the kernel driver which acts on every write."""
        m = self.motors[i]
        cmd_path = os.path.join(m, "command")
        try:
            mt = os.stat(cmd_path).st_mtime_ns
        except OSError:
            mt = None
        event = None
        if mt != self._cmd_mtime[i]:
            # The robot writes with open(O_TRUNC) + write(); if we look exactly
            # in between we see an empty file: leave the mtime unconsumed and
            # pick the command up next tick instead of losing it.
            text = self._read(cmd_path)
            if text:
                self._cmd_mtime[i] = mt
                event = text
        try:
            speed_sp = int(self._read(os.path.join(m, "speed_sp")))
            self._speed_sp[i] = speed_sp
        except ValueError:
            speed_sp = self._speed_sp[i]  # caught mid-write: keep the last value
        return event, speed_sp, self._read(os.path.join(m, "stop_action")) or "coast"

    def set_motor_state(self, i, position, speed, running):
        m = self.motors[i]
        self._write(os.path.join(m, "position"), int(position))
        self._write(os.path.join(m, "speed"), int(speed))
        self._write(os.path.join(m, "state"), "running" if running else "")

# ------------------------------------------------------------------- robot

class Motor:
    """EV3 large motor: regulated speed follows the set-point with a first-order
    lag; `run-forever` uses speed_sp, `stop` brakes/coasts, `reset` zeroes."""
    MAX_SPEED = 1050.0  # deg/s (ev3dev max_speed for lego-ev3-l-motor)
    TAU = 0.08          # s, speed response time constant
    MAX_ACCEL = 4000.0  # deg/s^2, torque limit

    def __init__(self):
        self.target = 0.0   # deg/s
        self.speed = 0.0    # deg/s
        self.position = 0.0 # deg
        self.running = False
        self.stop_action = "coast"

    def command(self, cmd, speed_sp, stop_action):
        self.stop_action = stop_action
        if cmd == "run-forever":
            self.target = max(-self.MAX_SPEED, min(self.MAX_SPEED, float(speed_sp)))
            self.running = True
        elif cmd == "stop":
            self.running = False
            self.target = 0.0
        elif cmd == "reset":
            self.running = False
            self.target = 0.0
            self.speed = 0.0
            self.position = 0.0
            self.stop_action = "coast"

    def step(self, dt):
        if self.running:
            target = self.target
            tau = self.TAU
        elif self.stop_action in ("brake", "hold"):
            target, tau = 0.0, 0.05
        else:  # coast
            target, tau = 0.0, 0.5
        dv = (target - self.speed) * (dt / tau)
        lim = self.MAX_ACCEL * dt
        dv = max(-lim, min(lim, dv))
        self.speed += dv
        self.position += self.speed * dt


class Robot:
    WHEEL_RADIUS = 2.8      # cm  (EV3 56x28 tyre: 56 mm diameter)
    TRACK_WIDTH = 12.0      # cm  distance between wheel contact points
    SENSOR_AHEAD = 7.0      # cm  sensor in front of the axle
    SENSOR_SPOT = 0.8       # cm  radius of the illuminated spot
    WHITE, BLACK = 82, 8    # reflected light on floor / on the line

    def __init__(self, x, y, heading, noise=1.0, rng=None):
        self.x, self.y, self.heading = x, y, heading
        self.left, self.right = Motor(), Motor()
        self.noise = noise
        self.rng = rng or random.Random(1)
        # sample offsets covering the sensor spot (centre + ring)
        self.spot = [(0.0, 0.0)] + [(self.SENSOR_SPOT * 0.7 * math.cos(a), self.SENSOR_SPOT * 0.7 * math.sin(a))
                                    for a in [i * math.pi / 4 for i in range(8)]]

    def sensor_position(self):
        return (self.x + self.SENSOR_AHEAD * math.cos(self.heading),
                self.y + self.SENSOR_AHEAD * math.sin(self.heading))

    def step(self, dt):
        self.left.step(dt)
        self.right.step(dt)
        vl = math.radians(self.left.speed) * self.WHEEL_RADIUS   # cm/s
        vr = math.radians(self.right.speed) * self.WHEEL_RADIUS
        v = (vl + vr) / 2.0
        w = (vr - vl) / self.TRACK_WIDTH
        if abs(w) < 1e-9:
            self.x += v * math.cos(self.heading) * dt
            self.y += v * math.sin(self.heading) * dt
        else:  # exact arc integration
            r = v / w
            h0 = self.heading
            self.heading += w * dt
            self.x += r * (math.sin(self.heading) - math.sin(h0))
            self.y -= r * (math.cos(self.heading) - math.cos(h0))

    def reflect(self, track):
        """Reflected light 0..100 seen by the colour sensor."""
        sx, sy = self.sensor_position()
        c, s = math.cos(self.heading), math.sin(self.heading)
        dark = 0
        for ox, oy in self.spot:
            px, py = sx + ox * c - oy * s, sy + ox * s + oy * c
            d, _, _ = track.nearest(px, py)
            if d <= track.width / 2.0:
                dark += 1
        frac = dark / len(self.spot)
        value = self.WHITE - (self.WHITE - self.BLACK) * frac + self.rng.gauss(0, self.noise)
        return max(0, min(100, int(round(value))))

# -------------------------------------------------------------- rendering

def write_svg(path, track, trail, sensor_trail, title):
    x0, y0, x1, y1 = track.bbox
    pad = 20
    w, h = (x1 - x0) + 2 * pad, (y1 - y0) + 2 * pad
    scale = 4.0  # px per cm

    def P(x, y):
        return "%.1f,%.1f" % ((x - x0 + pad) * scale, (y1 - y + pad) * scale)

    poly = " ".join(P(x, y) for x, y in track.poly) + " " + P(*track.poly[0])
    out = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">'
           % (w * scale, h * scale, w * scale, h * scale),
           '<rect width="100%" height="100%" fill="#f7f5ef"/>',
           '<polyline points="%s" fill="none" stroke="#111" stroke-width="%.1f" stroke-linejoin="round"/>'
           % (poly, track.width * scale)]
    if trail:
        n = len(trail)
        for i in range(1, n):
            hue = 200 + 140 * i / n
            out.append('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="hsl(%d,80%%,50%%)" stroke-width="2"/>'
                       % (*P(*trail[i - 1]).split(","), *P(*trail[i]).split(","), hue))
        out.append('<polyline points="%s" fill="none" stroke="#e63" stroke-width="1" stroke-dasharray="3,3"/>'
                   % " ".join(P(x, y) for x, y in sensor_trail))
        out.append('<circle cx="%s" cy="%s" r="5" fill="#2a2"/>' % tuple(P(*trail[0]).split(",")))
        out.append('<circle cx="%s" cy="%s" r="5" fill="#c22"/>' % tuple(P(*trail[-1]).split(",")))
    out.append('<text x="8" y="16" font-family="sans-serif" font-size="12">%s</text>' % title)
    out.append('<text x="8" y="30" font-family="sans-serif" font-size="10">blue→red: robot centre over time; '
               'dashed: sensor; green/red dots: start/end</text>')
    out.append("</svg>")
    with open(path, "w") as f:
        f.write("\n".join(out))

# --------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--robot", required=True, help="robot program (ELF). Run natively, or via --runner")
    ap.add_argument("--runner", default=None,
                    help="program used to run the robot binary, e.g. qemu-arm-static (extra args after '--')")
    ap.add_argument("--track", default="kidney", choices=sorted(TRACKS))
    ap.add_argument("--duration", type=float, default=40.0, help="seconds of simulated (= wall-clock) time")
    ap.add_argument("--laps", type=float, default=1.0, help="laps required for success")
    ap.add_argument("--max-deviation", type=float, default=4.0,
                    help="cm: sensor farther than this from the line centre counts as 'lost'")
    ap.add_argument("--rate", type=float, default=200.0, help="physics/sensor update rate, Hz")
    ap.add_argument("--noise", type=float, default=1.0, help="sensor noise sigma (reflect units)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--svg", default=None, help="write a picture of the run")
    ap.add_argument("--sysfs-root", default=None, help="keep the fake sysfs here instead of a temp dir")
    ap.add_argument("--env", action="append", default=[], help="extra VAR=VALUE for the robot process")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("runner_args", nargs="*", help="arguments for --runner (after '--')")
    args = ap.parse_args()

    track = Track(TRACKS[args.track])
    # Start with the sensor on the left edge of the line, heading along the track.
    sx, sy, heading = track.pose_at(0.0)
    nx, ny = -math.sin(heading), math.cos(heading)          # left normal
    edge = track.width / 2.0
    sensor_x, sensor_y = sx + nx * edge, sy + ny * edge
    robot = Robot(sensor_x - Robot.SENSOR_AHEAD * math.cos(heading),
                  sensor_y - Robot.SENSOR_AHEAD * math.sin(heading), heading,
                  noise=args.noise, rng=random.Random(args.seed))

    root = args.sysfs_root or tempfile.mkdtemp(prefix="ev3sim-sysfs-")
    if args.sysfs_root and os.path.exists(root):
        shutil.rmtree(root)
    sysfs = FakeSysfs(root)
    sysfs.set_sensor(robot.reflect(track))

    env = dict(os.environ, EV3C_SYSFS_ROOT=root)
    for kv in args.env:
        k, _, v = kv.partition("=")
        env[k] = v
    cmd = ([args.runner] + args.runner_args if args.runner else []) + [args.robot]
    log = (lambda *a: None) if args.quiet else (lambda *a: print(*a, file=sys.stderr))
    log("ev3sim: sysfs at %s" % root)
    log("ev3sim: running %s" % " ".join(cmd))
    proc = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    os.set_blocking(proc.stdout.fileno(), False)

    dt = 1.0 / args.rate
    t0 = time.monotonic()
    t = 0.0
    tick = 0
    trail, sensor_trail = [], []
    progress = 0.0          # unwrapped arc length of the sensor along the track
    last_s = track.nearest(*robot.sensor_position())[1]
    lost_at = None
    max_dev = 0.0
    min_reflect, max_reflect = 100, 0
    robot_out = ""
    status = "timeout"
    try:
        while t < args.duration:
            # --- robot side -> physics
            for i, motor in enumerate((robot.left, robot.right)):
                ev, speed_sp, stop_action = sysfs.poll_motor(i)
                if ev:
                    motor.command(ev, speed_sp, stop_action)
            robot.step(dt)
            t += dt
            tick += 1
            # --- physics -> robot side (sensor at every tick, motor state at 20 Hz)
            value = robot.reflect(track)
            sysfs.set_sensor(value)
            min_reflect, max_reflect = min(min_reflect, value), max(max_reflect, value)
            if tick % int(args.rate / 20) == 0:
                for i, motor in enumerate((robot.left, robot.right)):
                    sysfs.set_motor_state(i, motor.position, motor.speed, motor.running)
            # --- bookkeeping
            d, s, _ = track.nearest(*robot.sensor_position())
            ds = s - last_s
            if ds > track.length / 2:
                ds -= track.length
            elif ds < -track.length / 2:
                ds += track.length
            progress += ds
            last_s = s
            if tick % int(args.rate / 20) == 0:
                trail.append((robot.x, robot.y))
                sensor_trail.append(robot.sensor_position())
            if t > 1.0:
                max_dev = max(max_dev, d)
                if d > args.max_deviation and lost_at is None:
                    lost_at = t
            # --- robot stdout passthrough
            try:
                chunk = proc.stdout.read()
            except (OSError, TypeError):
                chunk = None
            if chunk:
                robot_out += chunk
                for line in chunk.splitlines():
                    log("[robot] " + line)
            if proc.poll() is not None:
                status = "robot exited (%d)" % proc.returncode
                break
            if lost_at is not None:
                status = "lost the line at t=%.1fs" % lost_at
                break
            if progress >= args.laps * track.length:
                status = "completed %.2f laps at t=%.1fs" % (progress / track.length, t)
                break
            # --- real time pacing
            sleep_for = t0 + t - time.monotonic()
            if sleep_for > 0:
                time.sleep(sleep_for)
            elif sleep_for < -0.5 and tick % int(args.rate) == 0:
                log("ev3sim: warning, simulation is %.1fs behind real time" % -sleep_for)
    finally:
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
        try:
            rest = proc.stdout.read()
        except (OSError, TypeError):
            rest = None
        if rest:
            for line in rest.splitlines():
                log("[robot] " + line)
        if not args.sysfs_root:
            shutil.rmtree(root, ignore_errors=True)

    laps = progress / track.length
    ok = laps >= args.laps and lost_at is None
    summary = ("ev3sim: %s | track=%s (%.0f cm) | laps=%.2f | max sensor deviation=%.1f cm | "
               "reflect %d..%d | %s"
               % ("PASS" if ok else "FAIL", args.track, track.length, laps, max_dev, min_reflect,
                  max_reflect, status))
    print(summary)
    if args.svg:
        write_svg(args.svg, track, trail, sensor_trail, summary.replace("ev3sim: ", ""))
        log("ev3sim: wrote %s" % args.svg)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
