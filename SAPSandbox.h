#import <Foundation/Foundation.h>

// Extends Safari's sandbox for the file picker (read only). Returns a message for
// the picker's start page when something could not be granted, nil otherwise.
NSString *SAPEnsureFileAccess(void);

// YES once SafariPicker_SystemAccess was granted in this Safari launch. Stays YES after the
// setting is turned off, because sandbox extensions cannot be revoked.
BOOL SAPSystemAccessGranted(void);
