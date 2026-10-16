// Long-press the Share button in Safari's toolbar to open "Find on Page".
// Based on SafariFind.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SAPDiagnostics.h"
#import "SAPPrefs.h"

@interface _UIButtonBarButton : UIControl
- (void)setContextMenuEnabled:(BOOL)enabled;
- (void)configureFromBarItem:(UIBarButtonItem *)item withAppearanceDelegate:(id)delegate;
@end

@interface BrowserRootViewController : UIViewController
- (id)delegate;       // BrowserController
@end

@interface BrowserController : NSObject
- (void)find:(id)sender;     // iOS 16+
- (void)findKeyPressed;      // iOS 15
@end

@interface _UIButtonBarButton (SAPShareFind)
- (void)sap_shareLongPressed:(UILongPressGestureRecognizer *)gesture;
@end

static const void *kSAPShareGestureKey = &kSAPShareGestureKey;
// UIKit default is 0.5s; anything much shorter starts eating normal taps.
static const NSTimeInterval kSAPSharePressDuration = 0.3;
// Roughly how long Find takes to appear; raise it if the haptic still fires early.
static const NSTimeInterval kSAPShareHapticDelay = 0.25;

// Safari tags each toolbar button with a non-localized accessibilityIdentifier
// ("BackButton", "ShareButton", ...). All items share the same action
// (-_itemReceivedTap:), so the identifier is the reliable discriminator.
static BOOL SAPIsShareButton(UIView *button)
{
	return [button.accessibilityIdentifier isEqualToString:@"ShareButton"];
}

// Find slides in asynchronously, so tap the haptic once it has settled.
static void SAPTapAfterFindAppears(void)
{
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSAPShareHapticDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
	});
}

// Safari turns Share's context menu back on whenever the toolbar refreshes (switching tabs),
// and the menu then swallows the long-press. Switching it off at every touch, before it
// starts lifting a preview, covers that without knowing when Safari does it.
@interface SAPShareGestureDelegate : NSObject <UIGestureRecognizerDelegate>
@end

@implementation SAPShareGestureDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch
{
	if(SAPPrefBool(kSAPPrefShareFind))
	{
		[(_UIButtonBarButton *)gestureRecognizer.view setContextMenuEnabled:NO];
	}
	return YES;
}

@end

// Applies the setting to a Share button: our gesture on, Share's own context menu off, or the reverse
static void SAPApplyShareFind(_UIButtonBarButton *button)
{
	// Bar buttons get reused and reconfigured, so the setting is applied here as well as when
	// the gesture fires; a change shows up the next time Safari reconfigures the toolbar
	BOOL enabled = SAPPrefBool(kSAPPrefShareFind);
	UILongPressGestureRecognizer *gesture = objc_getAssociatedObject(button, kSAPShareGestureKey);

	if(!enabled && !gesture)
	{
		return;
	}

	// Share has its own long-press context menu on iOS 15+, which would swallow our gesture
	[button setContextMenuEnabled:!enabled];

	if(!gesture)
	{
		static SAPShareGestureDelegate *gestureDelegate;
		static dispatch_once_t once;
		dispatch_once(&once, ^{ gestureDelegate = [SAPShareGestureDelegate new]; });

		gesture = [[UILongPressGestureRecognizer alloc] initWithTarget:button action:@selector(sap_shareLongPressed:)];
		gesture.minimumPressDuration = kSAPSharePressDuration;
		gesture.delegate = gestureDelegate;
		[button addGestureRecognizer:gesture];
		objc_setAssociatedObject(button, kSAPShareGestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		SAPLog(@"attached long-press to %@", button);
	}
	gesture.enabled = enabled;
}

%hook _UIButtonBarButton

- (void)configureFromBarItem:(UIBarButtonItem *)item withAppearanceDelegate:(id)delegate
{
	%orig;

	if(SAPIsShareButton(self))
	{
		SAPApplyShareFind(self);
	}
}

- (void)didMoveToWindow
{
	%orig;

	if(self.window && SAPIsShareButton(self))
	{
		SAPApplyShareFind(self);
	}
}

%new
- (void)sap_shareLongPressed:(UILongPressGestureRecognizer *)gesture
{
	// Bar buttons get reused, so make sure this one is still Share
	if(gesture.state != UIGestureRecognizerStateBegan || !SAPIsShareButton(self) || !SAPPrefBool(kSAPPrefShareFind))
	{
		return;
	}

	UIResponder *responder = self;
	while(responder && ![responder isKindOfClass:%c(BrowserRootViewController)])
	{
		responder = responder.nextResponder;
	}

	id controller = [(BrowserRootViewController *)responder delegate];
	SAPLog(@"long-press recognized, root=%@, delegate=%@", responder, controller);
	if(!controller)
	{
		return;
	}

	if(@available(iOS 16, *))
	{
		[(BrowserController *)controller find:nil];
	}
	else
	{
		[(BrowserController *)controller findKeyPressed];
	}
	SAPTapAfterFindAppears();
}

%end

%ctor
{
	if(!objc_getClass("_UIButtonBarButton") || !objc_getClass("BrowserRootViewController"))
	{
		SAPLog(@"toolbar classes not found, Share long-press feature disabled");
		return;
	}

	%init;
}
