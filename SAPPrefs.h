// Settings shared by the tweak (in Safari) and the Settings pane.
// Stored as a plain plist inside the jailbreak, read directly by both sides.

#import <Foundation/Foundation.h>

#define kSAPPrefBothOpenOptions @"bothOpenOptionsEnabled"
#define kSAPPrefOppositeMode @"oppositeModeEnabled"
#define kSAPPrefUploadAnyFile @"uploadAnyFileEnabled"
#define kSAPPrefSystemFileAccess @"systemFileAccessEnabled"

// Real path (not jbroot): sandyd evaluates libSandy profile conditions without jbroot(),
// so SafariPicker_SystemAccess.plist names this exact path. Only the Settings pane writes it.
#define kSAPSystemAccessFlagPath @"/var/mobile/Library/Preferences/com.qn.safaripicker.system_access"

NSString *SAPPrefsFilePath(void);
NSDictionary<NSString *, id> *SAPPrefsDefaults(void);
NSDictionary<NSString *, id> *SAPReadPrefs(void);
BOOL SAPPrefBool(NSString *key);

// System file access only counts while Upload Any File is on, since only the picker uses it
BOOL SAPSystemFileAccessEnabled(void);
