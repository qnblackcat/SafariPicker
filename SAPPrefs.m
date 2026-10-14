#import "SAPPrefs.h"
// Theos' roothide.h falls back to a /var/jb stub when building SCHEME=rootless
#import <roothide.h>

NSString *SAPPrefsFilePath(void)
{
	return jbroot(@"/var/mobile/Library/Preferences/com.qn.safaripicker.plist");
}

NSDictionary<NSString *, id> *SAPPrefsDefaults(void)
{
	return @{
		kSAPPrefBothOpenOptions: @YES,
		kSAPPrefOppositeMode: @YES,
		kSAPPrefShareFind: @YES,
		kSAPPrefUploadAnyFile: @NO,
		kSAPPrefSystemFileAccess: @NO,
	};
}

// Read on every use so changes apply without restarting Safari
NSDictionary<NSString *, id> *SAPReadPrefs(void)
{
	return [NSDictionary dictionaryWithContentsOfFile:SAPPrefsFilePath()] ?: @{};
}

BOOL SAPPrefBool(NSString *key)
{
	id value = SAPReadPrefs()[key] ?: SAPPrefsDefaults()[key];
	return [value boolValue];
}

BOOL SAPSystemFileAccessEnabled(void)
{
	return SAPPrefBool(kSAPPrefUploadAnyFile) && SAPPrefBool(kSAPPrefSystemFileAccess);
}
