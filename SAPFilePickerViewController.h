#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Called once; nil means the user cancelled
typedef void (^SAPFilePickerCompletion)(NSArray<NSURL *> *_Nullable fileURLs);

@interface SAPFilePickerViewController : UITableViewController

// accessError is shown on the start page when the sandbox could not be extended
+ (UINavigationController *)navigationControllerAllowingMultipleSelection:(BOOL)allowsMultipleSelection
	accessError:(nullable NSString *)accessError
	completion:(SAPFilePickerCompletion)completion;

@end

NS_ASSUME_NONNULL_END
