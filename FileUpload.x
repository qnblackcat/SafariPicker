// Upload any file: adds "Local Files" to the <input type="file"> menu.
// Based on WebKit's WKFileUploadPanel (iOS 16 / 17 sources: WebKit-7615 / 7617).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SAPFilePickerViewController.h"
#import "SAPDiagnostics.h"
#import "SAPPrefs.h"
#import "SAPSandbox.h"

@interface WKFileUploadPanel : UIViewController <UIAdaptivePresentationControllerDelegate>
- (void)_chooseFiles:(NSArray<NSURL *> *)fileURLs displayString:(NSString *)displayString iconImage:(UIImage *)iconImage;
- (void)_cancel;
- (void)_presentFullscreenViewController:(UIViewController *)viewController animated:(BOOL)animated;
- (void)showFilePickerMenu;
- (void)sap_presentSourceChooser;
- (void)sap_presentLocalFilePicker;
- (void)sap_chooseLocalFiles:(NSArray<NSURL *> *)fileURLs;
@end

@interface UIContextMenuConfiguration (SAPPrivate)
@property (nonatomic, copy) UIContextMenuActionProvider actionProvider;
@end

static const void *kSAPBypassChooserKey = &kSAPBypassChooserKey;
static const void *kSAPFinishedKey = &kSAPFinishedKey;

static BOOL SAPGetBoolIvar(id obj, const char *name, BOOL *outValue)
{
	Ivar ivar = obj ? class_getInstanceVariable(object_getClass(obj), name) : NULL;
	if(!ivar)
	{
		return NO;
	}
	*outValue = *(BOOL *)((uint8_t *)(__bridge void *)obj + ivar_getOffset(ivar));
	return YES;
}

static void SAPSetBoolIvar(id obj, const char *name, BOOL value)
{
	Ivar ivar = obj ? class_getInstanceVariable(object_getClass(obj), name) : NULL;
	if(ivar)
	{
		*(BOOL *)((uint8_t *)(__bridge void *)obj + ivar_getOffset(ivar)) = value;
	}
}

static NSURL *SAPUploadDirectory(void)
{
	return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"SafariPicker"] isDirectory:YES];
}

// WebKit hands the chosen paths to the web content and networking processes. Copying into
// Safari's tmp directory (as WebKit does for Files app picks) keeps them readable there.
static NSArray<NSURL *> *SAPCopyForUpload(NSArray<NSURL *> *fileURLs)
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSMutableArray<NSURL *> *uploadURLs = [NSMutableArray arrayWithCapacity:fileURLs.count];

	for(NSURL *fileURL in fileURLs)
	{
		NSURL *directory = [SAPUploadDirectory() URLByAppendingPathComponent:[NSUUID UUID].UUIDString isDirectory:YES];
		NSURL *destination = [directory URLByAppendingPathComponent:fileURL.lastPathComponent];

		NSError *error;
		if([fileManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error] &&
		   [fileManager copyItemAtURL:fileURL.URLByResolvingSymlinksInPath toURL:destination error:&error])
		{
			[uploadURLs addObject:destination];
		}
		else
		{
			SAPLog(@"Copy of %@ failed (%@), passing the original path", fileURL.path, error);
			[uploadURLs addObject:fileURL];
		}
	}

	return uploadURLs;
}

%hook WKFileUploadPanel

// Menu shown when the page accepts images / videos
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location
{
	UIContextMenuConfiguration *config = %orig;
	if(!SAPPrefBool(kSAPPrefUploadAnyFile))
	{
		return config;
	}

	UIContextMenuActionProvider origProvider = [config respondsToSelector:@selector(actionProvider)] ? config.actionProvider : nil;
	if(!origProvider)
	{
		SAPLog(@"Upload menu: no actionProvider on %@", config);
		return config;
	}

	__weak WKFileUploadPanel *weakSelf = self;
	UIContextMenuActionProvider provider = ^UIMenu *(NSArray<UIMenuElement *> *suggestedActions)
	{
		UIMenu *menu = origProvider(suggestedActions);
		if(!menu)
		{
			return menu;
		}

		UIAction *localFilesAction = [UIAction actionWithTitle:@"Local Files"
			image:[UIImage systemImageNamed:@"internaldrive"]
			identifier:@"com.qn.safaripicker.local-files"
			handler:^(__kindof UIAction *action)
		{
			WKFileUploadPanel *panel = weakSelf;
			// Stops WebKit from cancelling the upload when the menu closes
			SAPSetBoolIvar(panel, "_isPresentingSubMenu", YES);
			[panel sap_presentLocalFilePicker];
		}];

		return [menu menuByReplacingChildren:[menu.children arrayByAddingObject:localFilesAction]];
	};

	if([config respondsToSelector:@selector(setActionProvider:)])
	{
		config.actionProvider = provider;
		return config;
	}
	return [UIContextMenuConfiguration configurationWithIdentifier:config.identifier previewProvider:nil actionProvider:provider];
}

// Called directly (no menu) when the page accepts neither images nor videos,
// and from the menu's "Choose File" item
- (void)showFilePickerMenu
{
	BOOL fromMenu = NO;
	SAPGetBoolIvar(self, "_isPresentingSubMenu", &fromMenu);

	if(fromMenu || [objc_getAssociatedObject(self, kSAPBypassChooserKey) boolValue] || !SAPPrefBool(kSAPPrefUploadAnyFile))
	{
		%orig;
		return;
	}

	[self sap_presentSourceChooser];
}

- (void)_cancel
{
	objc_setAssociatedObject(self, kSAPFinishedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	%orig;
}

- (void)_chooseFiles:(NSArray<NSURL *> *)fileURLs displayString:(NSString *)displayString iconImage:(UIImage *)iconImage
{
	objc_setAssociatedObject(self, kSAPFinishedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	%orig;
}

%new
- (void)sap_presentSourceChooser
{
	BOOL isPad = [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad;
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:nil
		preferredStyle:isPad ? UIAlertControllerStyleAlert : UIAlertControllerStyleActionSheet];

	__weak WKFileUploadPanel *weakSelf = self;

	[alert addAction:[UIAlertAction actionWithTitle:@"Files" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action)
	{
		WKFileUploadPanel *panel = weakSelf;
		objc_setAssociatedObject(panel, kSAPBypassChooserKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[panel showFilePickerMenu];
	}]];

	[alert addAction:[UIAlertAction actionWithTitle:@"Local Files" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action)
	{
		[weakSelf sap_presentLocalFilePicker];
	}]];

	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action)
	{
		[weakSelf _cancel];
	}]];

	[self _presentFullscreenViewController:alert animated:YES];
}

%new
- (void)sap_presentLocalFilePicker
{
	NSString *accessError = SAPEnsureFileAccess();

	BOOL allowsMultipleSelection = NO;
	SAPGetBoolIvar(self, "_allowMultipleFiles", &allowsMultipleSelection);

	// The picker keeps the panel alive until it finishes
	WKFileUploadPanel *panel = self;
	__block __weak UINavigationController *weakNavigationController;

	UINavigationController *navigationController = [SAPFilePickerViewController
		navigationControllerAllowingMultipleSelection:allowsMultipleSelection
		accessError:accessError
		completion:^(NSArray<NSURL *> *fileURLs)
	{
		[weakNavigationController dismissViewControllerAnimated:YES completion:nil];
		[panel sap_chooseLocalFiles:fileURLs];
	}];
	weakNavigationController = navigationController;

	// Swiping the sheet away ends up in -presentationControllerDidDismiss:, which cancels
	navigationController.presentationController.delegate = self;
	[self _presentFullscreenViewController:navigationController animated:YES];
}

%new
- (void)sap_chooseLocalFiles:(NSArray<NSURL *> *)fileURLs
{
	if(!fileURLs.count)
	{
		[self _cancel];
		return;
	}

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSArray<NSURL *> *uploadURLs = SAPCopyForUpload(fileURLs);

		dispatch_async(dispatch_get_main_queue(), ^{
			if([objc_getAssociatedObject(self, kSAPFinishedKey) boolValue])
			{
				SAPLog(@"Upload panel already finished, dropping %lu file(s)", (unsigned long)uploadURLs.count);
				return;
			}

			NSString *displayString = uploadURLs.count == 1
				? fileURLs.firstObject.lastPathComponent
				: [NSString stringWithFormat:@"%lu files", (unsigned long)uploadURLs.count];
			[self _chooseFiles:uploadURLs displayString:displayString iconImage:[UIImage systemImageNamed:@"doc.fill"]];
		});
	});
}

%end

%ctor
{
	if(!objc_getClass("WKFileUploadPanel"))
	{
		SAPLog(@"WKFileUploadPanel not found, upload feature disabled");
		return;
	}

	// Copies from earlier sessions are no longer referenced by any page
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
		[[NSFileManager defaultManager] removeItemAtURL:SAPUploadDirectory() error:nil];
	});

	%init;
}
