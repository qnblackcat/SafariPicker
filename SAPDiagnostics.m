// Dumps the private selectors this tweak relies on, so a failing feature on a new
// iOS version can be fixed from a log instead of a class-dump.
// Read with: oslog | grep SafariPicker   (or Console.app on a Mac)

#import "SAPDiagnostics.h"
#import <objc/runtime.h>

#if SAP_DIAGNOSTICS

static void SAPDumpMethods(NSString *className, NSArray<NSString *> *keywords)
{
	Class cls = NSClassFromString(className);
	if(!cls)
	{
		SAPLog(@"class %@: NOT FOUND", className);
		return;
	}

	NSMutableArray<NSString *> *matches = [NSMutableArray new];
	unsigned int count = 0;
	Method *methods = class_copyMethodList(cls, &count);
	for(unsigned int i = 0; i < count; i++)
	{
		NSString *name = NSStringFromSelector(method_getName(methods[i]));
		for(NSString *keyword in keywords)
		{
			if([name rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound)
			{
				[matches addObject:name];
				break;
			}
		}
	}
	free(methods);

	[matches sortUsingSelector:@selector(compare:)];
	SAPLog(@"class %@ (%u methods), matching: %@", className, count, [matches componentsJoinedByString:@" "]);
}

static void SAPDumpProtocol(NSString *protocolName)
{
	Protocol *protocol = NSProtocolFromString(protocolName);
	if(!protocol)
	{
		SAPLog(@"protocol %@: NOT FOUND", protocolName);
		return;
	}

	NSMutableArray<NSString *> *names = [NSMutableArray new];
	BOOL requiredValues[] = { YES, NO };
	for(size_t i = 0; i < 2; i++)
	{
		unsigned int count = 0;
		struct objc_method_description *methods = protocol_copyMethodDescriptionList(protocol, requiredValues[i], YES, &count);
		for(unsigned int j = 0; j < count; j++)
		{
			[names addObject:NSStringFromSelector(methods[j].name)];
		}
		free(methods);
	}

	[names sortUsingSelector:@selector(compare:)];
	SAPLog(@"protocol %@: %@", protocolName, [names componentsJoinedByString:@" "]);
}

__attribute__((constructor)) static void SAPDiagnosticsInit(void)
{
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		SAPLog(@"=== diagnostics, iOS %@ ===", [[NSProcessInfo processInfo] operatingSystemVersionString]);
		SAPDumpMethods(@"_SFLinkPreviewHelper", @[@"menu", @"openIn", @"openURL", @"url", @"handler"]);
		SAPDumpProtocol(@"_SFLinkPreviewHandler");
		SAPDumpMethods(@"TabController", @[@"canAddNewTab", @"private"]);
		SAPDumpMethods(@"BrowserController", @[@"private", @"loadURLInNewTab", @"tabController"]);
		SAPDumpMethods(@"TabDocument", @[@"browserController", @"loadURL", @"private"]);
		SAPDumpMethods(@"WKFileUploadPanel", @[@"choose", @"cancel", @"present", @"Picker", @"contextMenu"]);

		Class panel = NSClassFromString(@"WKFileUploadPanel");
		SAPLog(@"WKFileUploadPanel ivars: _isPresentingSubMenu=%d _allowMultipleFiles=%d",
			class_getInstanceVariable(panel, "_isPresentingSubMenu") != NULL,
			class_getInstanceVariable(panel, "_allowMultipleFiles") != NULL);
	});
}

#endif
