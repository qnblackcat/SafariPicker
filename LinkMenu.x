// Link long-press menu:
//  - "Open in New Tab" and "Open in Background" shown side by side
//  - "Open in Private Mode" / "Open in Normal Mode"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SAPDiagnostics.h"
#import "SAPPrefs.h"

@interface _SFLinkPreviewHelper : NSObject
- (NSURL *)url;
@end

// iOS 15.2.1 / 16.3 / 17.1 headers; still checked with respondsToSelector: since they are private
@interface TabController : NSObject
- (BOOL)canAddNewTabForPrivateBrowsing:(BOOL)privateBrowsing;
@end

@interface BrowserController : NSObject
- (TabController *)tabController;
- (BOOL)isPrivateBrowsingEnabled;
- (BOOL)privateBrowsingEnabled;
- (BOOL)isPrivateBrowsingAvailable;
- (void)togglePrivateBrowsingEnabled;
- (void)loadURLInNewTab:(NSURL *)url inBackground:(BOOL)inBackground animated:(BOOL)animated;
@end

@interface TabDocument : NSObject
- (BrowserController *)browserController;
@end

@interface UIAction (SAPPrivate)
@property (nonatomic, copy) UIActionHandler handler;
@end

#pragma mark - OpenLinksInBackground faking

// Safari builds its single "Open in New Tab" / "Open in Background" action from this
// user default. Faking it lets us get both variants out of Safari's own code.
static NSString *const kOpenLinksInBackgroundKey = @"OpenLinksInBackground";
static BOOL sapFakeOpenLinksKey = NO;
static BOOL sapFakeOpenLinksValue = NO;

static void SAPWithFakedOpenLinksInBackground(BOOL value, void (^block)(void))
{
	BOOL prevFake = sapFakeOpenLinksKey;
	BOOL prevValue = sapFakeOpenLinksValue;

	sapFakeOpenLinksKey = YES;
	sapFakeOpenLinksValue = value;
	block();
	sapFakeOpenLinksKey = prevFake;
	sapFakeOpenLinksValue = prevValue;
}

%hook NSUserDefaults

- (BOOL)boolForKey:(NSString *)key
{
	if(sapFakeOpenLinksKey && [key isEqualToString:kOpenLinksInBackgroundKey])
	{
		return sapFakeOpenLinksValue;
	}

	return %orig;
}

- (id)objectForKey:(NSString *)key
{
	if(sapFakeOpenLinksKey && [key isEqualToString:kOpenLinksInBackgroundKey])
	{
		return @(sapFakeOpenLinksValue);
	}

	return %orig;
}

%end

// Make the action keep the faked value while it runs, so the tab really opens the way its title says
static void SAPPinOpenLinksValue(UIAction *action, BOOL inBackground)
{
	if(![action respondsToSelector:@selector(handler)] || ![action respondsToSelector:@selector(setHandler:)])
	{
		return;
	}

	UIActionHandler origHandler = action.handler;
	if(!origHandler)
	{
		return;
	}

	action.handler = ^(__kindof UIAction *a)
	{
		SAPWithFakedOpenLinksInBackground(inBackground, ^{
			origHandler(a);
		});
	};
}

// fg/bg are the same menu built with OpenLinksInBackground = NO / YES.
// The one action whose title differs is Safari's open-in-tab action. Returns a copy of fg
// with the background variant (and optional extra action) inserted after it, or nil if not found.
static NSArray<UIMenuElement *> *SAPMergeOpenActions(NSArray<UIMenuElement *> *fg, NSArray<UIMenuElement *> *bg, UIAction *extraAction)
{
	if(fg.count != bg.count)
	{
		return nil;
	}

	for(NSUInteger i = 0; i < fg.count; i++)
	{
		UIMenuElement *a = fg[i];
		UIMenuElement *b = bg[i];

		if([a isKindOfClass:[UIAction class]] && [b isKindOfClass:[UIAction class]])
		{
			if([a.title isEqualToString:b.title])
			{
				continue;
			}

			SAPPinOpenLinksValue((UIAction *)a, NO);
			SAPPinOpenLinksValue((UIAction *)b, YES);

			NSMutableArray *merged = [fg mutableCopy];
			[merged insertObject:b atIndex:i + 1];
			if(extraAction)
			{
				[merged insertObject:extraAction atIndex:i + 2];
			}
			return merged;
		}
		else if([a isKindOfClass:[UIMenu class]] && [b isKindOfClass:[UIMenu class]])
		{
			NSArray *children = SAPMergeOpenActions(((UIMenu *)a).children, ((UIMenu *)b).children, extraAction);
			if(children)
			{
				NSMutableArray *merged = [fg mutableCopy];
				merged[i] = [(UIMenu *)a menuByReplacingChildren:children];
				return merged;
			}
		}
	}

	return nil;
}

// Used when Safari's open-in-tab action can't be located: after the first two items
static NSArray<UIMenuElement *> *SAPInsertingAction(NSArray<UIMenuElement *> *elements, UIAction *action)
{
	if(!action)
	{
		return elements;
	}

	NSMutableArray<UIMenuElement *> *result = [elements mutableCopy];
	[result insertObject:action atIndex:MIN((NSUInteger)2, result.count)];
	return result;
}

#pragma mark - Opposite browsing mode

static id SAPGetIvar(id obj, const char *name)
{
	Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
	return ivar ? object_getIvar(obj, ivar) : nil;
}

// The helper's _handler is the TabDocument the link was pressed in (iOS 16.3 / 17.1 headers)
static BrowserController *SAPBrowserControllerForTabDocument(TabDocument *tabDocument)
{
	if(!tabDocument)
	{
		return nil;
	}

	if([tabDocument respondsToSelector:@selector(browserController)])
	{
		return [tabDocument browserController];
	}

	return SAPGetIvar(tabDocument, "_browserController");
}

static BOOL SAPIsPrivateBrowsing(TabDocument *tabDocument, BrowserController *browserController)
{
	for(id object in @[tabDocument ?: [NSNull null], browserController ?: [NSNull null]])
	{
		if([object respondsToSelector:@selector(isPrivateBrowsingEnabled)])
		{
			return [object isPrivateBrowsingEnabled];
		}
		if([object respondsToSelector:@selector(privateBrowsingEnabled)])
		{
			return [object privateBrowsingEnabled];
		}
	}
	return NO;
}

// -[TabController canAddNewTabForPrivateBrowsing:] exists on iOS 15.2.1 and 17.1
static BOOL SAPCanOpenTab(BrowserController *browserController, BOOL privateBrowsing)
{
	TabController *tabController = [browserController respondsToSelector:@selector(tabController)] ? [browserController tabController] : nil;
	if([tabController respondsToSelector:@selector(canAddNewTabForPrivateBrowsing:)])
	{
		return [tabController canAddNewTabForPrivateBrowsing:privateBrowsing];
	}

	if(privateBrowsing && [browserController respondsToSelector:@selector(isPrivateBrowsingAvailable)])
	{
		return [browserController isPrivateBrowsingAvailable];
	}
	return YES;
}

static UIAction *SAPOppositeModeAction(_SFLinkPreviewHelper *helper)
{
	NSURL *url = [helper respondsToSelector:@selector(url)] ? [helper url] : nil;
	TabDocument *tabDocument = SAPGetIvar(helper, "_handler");
	BrowserController *browserController = SAPBrowserControllerForTabDocument(tabDocument);
	if(!url || !browserController)
	{
		SAPLog(@"Opposite mode: missing url (%@) or browserController (%@)", url, browserController);
		return nil;
	}

	// Switching the window's mode and opening a tab is what Safari's own mode button does.
	// Both selectors exist on BrowserController in iOS 15.2.1 and 17.1.
	if(![browserController respondsToSelector:@selector(togglePrivateBrowsingEnabled)] ||
	   ![browserController respondsToSelector:@selector(loadURLInNewTab:inBackground:animated:)])
	{
		SAPLog(@"Opposite mode: %@ lacks toggle / loadURLInNewTab, hiding item", [browserController class]);
		return nil;
	}

	BOOL privateBrowsing = SAPIsPrivateBrowsing(tabDocument, browserController);
	if(!SAPCanOpenTab(browserController, !privateBrowsing))
	{
		return nil;
	}

	__weak BrowserController *weakBrowserController = browserController;
	NSString *title = privateBrowsing ? @"Open in Normal Mode" : @"Open in Private Mode";
	return [UIAction actionWithTitle:title
		image:[UIImage systemImageNamed:@"arrow.uturn.right.square"]
		identifier:@"com.qn.safaripicker.opposite-mode"
		handler:^(__kindof UIAction *action)
	{
		BrowserController *bc = weakBrowserController;
		[bc togglePrivateBrowsingEnabled];
		[bc loadURLInNewTab:url inBackground:NO animated:YES];
		SAPLog(@"Opposite mode: opened link, window private now %d (wanted %d)", SAPIsPrivateBrowsing(nil, bc), !privateBrowsing);
	}];
}

#pragma mark - Hook

%hook _SFLinkPreviewHelper

- (NSArray<UIMenuElement *> *)menuElementsForSuggestedActions:(NSArray *)suggestedActions
{
	UIAction *oppositeAction = SAPPrefBool(kSAPPrefOppositeMode) ? SAPOppositeModeAction(self) : nil;

	if(SAPPrefBool(kSAPPrefBothOpenOptions))
	{
		__block NSArray<UIMenuElement *> *foregroundElements;
		__block NSArray<UIMenuElement *> *backgroundElements;

		SAPWithFakedOpenLinksInBackground(NO, ^{
			foregroundElements = %orig;
		});
		SAPWithFakedOpenLinksInBackground(YES, ^{
			backgroundElements = %orig;
		});

		NSArray<UIMenuElement *> *merged = SAPMergeOpenActions(foregroundElements, backgroundElements, oppositeAction);
		if(merged)
		{
			return merged;
		}

		// Faking had no effect on this Safari; fall back to the menu as the user's setting builds it
		SAPLog(@"Both link options: could not find Safari's open-in-tab action");
	}

	return SAPInsertingAction(%orig, oppositeAction);
}

// Every open action ends here (iOS 16.3 / 17.1 headers). Logged to learn the enum values,
// in case forcing tabOrder is ever needed instead of faking OpenLinksInBackground.
- (void)openURL:(NSURL *)url forAction:(long long)action withTabOrder:(long long)tabOrder
{
	SAPLog(@"openURL:forAction:%lld withTabOrder:%lld (faking: %d, value: %d)", action, tabOrder, sapFakeOpenLinksKey, sapFakeOpenLinksValue);
	%orig;
}

%end

%ctor
{
	Class helperClass = objc_getClass("_SFLinkPreviewHelper");
	if(!class_getInstanceMethod(helperClass, @selector(menuElementsForSuggestedActions:)))
	{
		SAPLog(@"_SFLinkPreviewHelper -menuElementsForSuggestedActions: not found, link menu features disabled");
		return;
	}

	%init;
}
