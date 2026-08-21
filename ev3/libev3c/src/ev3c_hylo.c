/* Hylo-facing thunks for ev3c.
 *
 * Hylo (v0.0.6) calls C through `@extern_c_indirect`: every parameter is
 * passed by pointer and the result is written through a trailing pointer
 * (see Docs/ABI.md in the Hylo repository). These one-liners adapt the plain
 * C API in ev3c.h to that convention. Int32 <-> int32_t, Bool <-> char.
 */
#include "ev3c.h"

#include <stdint.h>

void ev3_init_indirect(int32_t* result) { *result = (int32_t)ev3c_init(); }
void ev3_shutdown_indirect(void) { ev3c_shutdown(); }
void ev3_running_indirect(char* result) { *result = (char)ev3c_running(); }
void ev3_color_reflect_indirect(int32_t* result) { *result = (int32_t)ev3c_color_reflect(); }
void ev3_drive_indirect(int32_t const* left, int32_t const* right) { ev3c_drive(*left, *right); }
void ev3_stop_indirect(void) { ev3c_stop(); }
void ev3_motor_position_indirect(int32_t const* side, int32_t* result) {
  *result = (int32_t)ev3c_motor_position(*side);
}
void ev3_sleep_ms_indirect(int32_t const* ms) { ev3c_sleep_ms(*ms); }
void ev3_millis_indirect(int32_t* result) { *result = (int32_t)ev3c_millis(); }
void ev3_log_indirect(int32_t const* tag, int32_t const* value) { ev3c_log(*tag, *value); }
