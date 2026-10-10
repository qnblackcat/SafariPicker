#import "SAPSandbox.h"
#import "SAPPrefs.h"
#import "SAPDiagnostics.h"
#import <libSandy.h>

// Extensions cannot be revoked, so each profile is applied at most once per Safari launch
static BOOL fileAccessApplied = NO;
static BOOL systemAccessApplied = NO;

BOOL SAPSystemAccessGranted(void)
{
	return systemAccessApplied;
}

NSString *SAPEnsureFileAccess(void)
{
	if(!fileAccessApplied)
	{
		int ret = libSandy_applyProfile("SafariPicker_FileAccess");
		SAPLog(@"libSandy_applyProfile(SafariPicker_FileAccess) = %d", ret);

		if(ret == kLibSandyErrorXPCFailure)
		{
			return @"Could not reach libSandy. Make sure libSandy is installed and userspace was rebooted. Only folders Safari can already read are listed.";
		}
		if(ret != kLibSandySuccess)
		{
			return @"libSandy refused the SafariPicker_FileAccess profile. Only folders Safari can already read are listed.";
		}
		fileAccessApplied = YES;
	}

	if(SAPSystemFileAccessEnabled() && !systemAccessApplied)
	{
		// sandyd also checks the Settings pane's flag file before granting this
		int ret = libSandy_applyProfile("SafariPicker_SystemAccess");
		SAPLog(@"libSandy_applyProfile(SafariPicker_SystemAccess) = %d", ret);

		if(ret != kLibSandySuccess)
		{
			return @"System file access is on in Settings but was not granted. Turn it off and on again in Settings › SafariPicker.";
		}
		systemAccessApplied = YES;
	}

	return nil;
}

__attribute__((constructor)) static void SAPSandboxInit(void)
{
	// Lets Safari read the settings plist in the jailbreak root's Preferences folder
	__unused int ret = libSandy_applyProfile("SafariPicker_Preferences");
	SAPLog(@"libSandy_applyProfile(SafariPicker_Preferences) = %d, prefs: %@", ret, SAPReadPrefs());
}
