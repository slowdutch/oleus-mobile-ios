#ifndef OLEUS_CRASH_CORE_H
#define OLEUS_CRASH_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Install async-signal-safe crash handlers (SIGABRT/SEGV/BUS/ILL/TRAP/FPE).
///
/// On a fatal signal the handler writes a plain-text report to `report_path`
/// using only async-signal-safe calls (no allocation, no ObjC/Swift runtime):
///
///     signal:11
///     name:SIGSEGV
///     fault:0x0000000000000010
///     0x0000000102f1a4b8
///     0x0000000102f1b2c0
///     ...
///
/// Frames are raw return addresses from a frame-pointer walk; the Swift layer
/// pairs them with the dyld image list on next launch for symbolication.
/// Previously installed handlers are chained after the report is written.
///
/// Returns 0 on success.
int oleus_crash_install(const char *report_path);

/// True if a report from a previous run exists and is non-empty.
int oleus_crash_has_pending(const char *report_path);

#ifdef __cplusplus
}
#endif

#endif /* OLEUS_CRASH_CORE_H */
