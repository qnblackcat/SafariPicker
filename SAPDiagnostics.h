#import <Foundation/Foundation.h>

#if SAP_DIAGNOSTICS
#define SAPLog(fmt, ...) NSLog(@"[SafariPicker] " fmt, ##__VA_ARGS__)
#else
#define SAPLog(fmt, ...)
#endif
