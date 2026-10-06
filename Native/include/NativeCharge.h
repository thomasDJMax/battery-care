#ifndef IADENTE_NATIVE_CHARGE_H
#define IADENTE_NATIVE_CHARGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Read operations never change charging settings. */
int IAChargeSupported(void);
int IAChargeCurrentLimit(void); /* -1 when unavailable */
int IAChargeEnabled(void);      /* 0 disabled, 1 enabled, -1 unavailable */

/* Call only for an explicit action in the app. Returns 1 on success. */
int IAChargeSetLimit(int limit, char *error, int capacity);
int IAChargeDisable(char *error, int capacity);

#ifdef __cplusplus
}
#endif
#endif
