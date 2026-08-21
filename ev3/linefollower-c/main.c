/* Line follower in plain C, using ev3c.
 *
 * Robot: two EV3 large motors on outB (left) and outC (right), one EV3 colour
 * sensor pointing at the floor a few cm in front of the wheel axle, following
 * the LEFT edge of a dark line on a light floor (the line is on the robot's
 * right). A proportional controller steers so the sensor keeps reading the
 * value halfway between "black" and "white".
 *
 * Tune without recompiling: EV3C_TARGET, EV3C_KP (x10), EV3C_BASE (percent),
 * EV3C_PERIOD (ms), e.g.  EV3C_KP=8 ./linefollower
 */
#include "ev3c.h"

#include <stdio.h>

int main(void) {
  if (ev3c_init() != 0) return 1;

  int target = ev3c_param("TARGET", 45); /* sensor value on the edge (black~10, white~80) */
  int kp10 = ev3c_param("KP", 12);       /* proportional gain * 10, in percent per unit */
  int base = ev3c_param("BASE", 30);     /* cruising speed, percent of max */
  int period = ev3c_param("PERIOD", 10); /* control period in ms */
  printf("linefollower: target=%d kp=%d/10 base=%d%% period=%dms\n", target, kp10, base, period);

  int iterations = 0;
  while (ev3c_running()) {
    int light = ev3c_color_reflect();
    if (light < 0) break; /* sensor unplugged */
    int error = light - target; /* >0: too much white -> drifted left -> steer right */
    int turn = error * kp10 / 10;
    if (turn > 60) turn = 60;
    if (turn < -60) turn = -60;
    ev3c_drive(base + turn, base - turn);
    if (++iterations % 100 == 0) printf("t=%dms light=%d turn=%d\n", ev3c_millis(), light, turn);
    ev3c_sleep_ms(period);
  }

  ev3c_shutdown();
  printf("linefollower: stopped after %d iterations\n", iterations);
  return 0;
}
