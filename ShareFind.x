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

%hook _UIButtonBarButton

- (void)configureFromBarItem:(UIBarButtonItem *)item withAppearanceDelegate:(id)delegate
{
	%orig;

	if(!SAPIsShareButton(self))
	{
		return;
	}

	// Bar buttons get reused and reconfigured, so the setting is applied here as well as when
	// the gesture fires; a change shows up the next time Safari reconfigures the toolbar
	BOOL enabled = SAPPrefBool(kSAPPrefShareFind);
	UILongPressGestureRecognizer *gesture = objc_getAssociatedObject(self, kSAPShareGestureKey);

	if(!enabled && !gesture)
	{
		return;
	}

	// Share has its own long-press context menu on iOS 15+, which would swallow our gesture
	[self setContextMenuEnabled:!enabled];

	if(!gesture)
	{
		gesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(sap_shareLongPressed:)];
		gesture.minimumPressDuration = kSAPSharePressDuration;
		[self addGestureRecognizer:gesture];
		objc_setAssociatedObject(self, kSAPShareGestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		SAPLog(@"attached long-press to %@", self);
	}
	gesture.enabled = enabled;
}

%new
- (void)sap_shareLongPressed:(UILongPressGestureRecognizer *)gesture
{
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
	SAPLog(@"long-press fired, root=%@, delegate=%@", responder, controller);
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
