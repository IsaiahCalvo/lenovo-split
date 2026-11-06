#ifndef LENOVO_DOCK_H
#define LENOVO_DOCK_H
#include <stdint.h>
typedef struct {
 int connected, monitors, mode, changed, wide;
 char error[256];
} LenovoDockState;
int lenovo_dock_connected(void);
int lenovo_dock_prepare(LenovoDockState *out);
// Reads verified controller state; never changes split mode or host EDID.
int lenovo_dock_check(LenovoDockState *out);
void lenovo_dock_forget_host_refresh(void);
#endif
