#import "SAPFilePickerViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <roothide.h>
#import "SAPDiagnostics.h"
#import "SAPPrefs.h"
#import "SAPSandbox.h"

#pragma mark - Shared picker state

@interface SAPFilePickerSession : NSObject
@property (nonatomic) BOOL allowsMultipleSelection;
@property (nonatomic, copy, nullable) NSString *accessError;
@property (nonatomic, copy, nullable) SAPFilePickerCompletion completion;
@property (nonatomic, strong) NSMutableOrderedSet<NSURL *> *selectedURLs;
- (void)finishWithURLs:(nullable NSArray<NSURL *> *)urls;
@end

@implementation SAPFilePickerSession

- (instancetype)init
{
	if((self = [super init]))
	{
		_selectedURLs = [NSMutableOrderedSet new];
	}
	return self;
}

- (void)finishWithURLs:(NSArray<NSURL *> *)urls
{
	SAPFilePickerCompletion completion = self.completion;
	self.completion = nil;
	if(completion)
	{
		completion(urls);
	}
}

@end

#pragma mark - Entries

@interface SAPFileEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic) BOOL isDirectory;
@property (nonatomic) BOOL isSymbolicLink;
@property (nonatomic, strong, nullable) NSURL *linkTargetURL; // symlinks only
@property (nonatomic, strong, nullable) NSNumber *fileSize;
@property (nonatomic, strong, nullable) NSDate *modificationDate;
@property (nonatomic, readonly) NSURL *targetURL;
@end

@implementation SAPFileEntry

// What gets browsed or uploaded: the link target for symlinks
- (NSURL *)targetURL
{
	return self.linkTargetURL ?: self.url;
}

@end

// realpath() can fail inside the sandbox even when the target itself is readable,
// so fall back to reading the link one level at a time
static NSURL *SAPResolveSymlink(NSURL *url)
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSString *path = url.path;

	for(int depth = 0; depth < 16; depth++)
	{
		NSString *destination = [fileManager destinationOfSymbolicLinkAtPath:path error:nil];
		if(!destination)
		{
			break;
		}
		if(!destination.isAbsolutePath)
		{
			destination = [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:destination];
		}
		path = destination.stringByStandardizingPath;
	}

	return [NSURL fileURLWithPath:path];
}

static NSString *SAPDescribeError(NSError *error)
{
	NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
	if([underlying.domain isEqualToString:NSPOSIXErrorDomain])
	{
		// The localized description just repeats strerror() after a generic sentence
		return [NSString stringWithUTF8String:strerror((int)underlying.code)];
	}
	return [NSString stringWithFormat:@"%@ (%@ %ld)", error.localizedDescription, error.domain, (long)error.code];
}

static NSArray<SAPFileEntry *> *SAPEntriesAtURL(NSURL *directoryURL, NSError **error)
{
	NSArray<NSURLResourceKey> *keys = @[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey, NSURLContentModificationDateKey];
	NSArray<NSURL *> *urls = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:directoryURL includingPropertiesForKeys:keys options:0 error:error];
	if(!urls)
	{
		return nil;
	}

	NSMutableArray<SAPFileEntry *> *entries = [NSMutableArray arrayWithCapacity:urls.count];
	for(NSURL *url in urls)
	{
		NSDictionary<NSURLResourceKey, id> *values = [url resourceValuesForKeys:keys error:nil];

		SAPFileEntry *entry = [SAPFileEntry new];
		entry.name = url.lastPathComponent;
		entry.url = url;
		entry.isSymbolicLink = [values[NSURLIsSymbolicLinkKey] boolValue];
		entry.isDirectory = [values[NSURLIsDirectoryKey] boolValue];
		entry.fileSize = values[NSURLFileSizeKey];
		entry.modificationDate = values[NSURLContentModificationDateKey];

		if(entry.isSymbolicLink)
		{
			// Browse / upload the link's target directly; going through the link path
			// itself is refused for some roothide links (e.g. AppGroup/.jbroot-*)
			entry.linkTargetURL = SAPResolveSymlink(url);

			BOOL isDirectory = NO;
			if([[NSFileManager defaultManager] fileExistsAtPath:entry.linkTargetURL.path isDirectory:&isDirectory])
			{
				NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:entry.linkTargetURL.path error:nil];
				entry.isDirectory = isDirectory;
				entry.fileSize = isDirectory ? nil : attributes[NSFileSize];
				entry.modificationDate = attributes[NSFileModificationDate];
			}
		}

		[entries addObject:entry];
	}

	return entries;
}

// Looked up at runtime (roothide's jbroot has a random suffix per device and install) and
// shown resolved, e.g. …/AppGroup/.jbroot-…/var on roothide or /private/preboot/…/var on
// rootless, so the path matches what browsing and Copy Path show.
static NSString *SAPJailbreakVarPath(void)
{
	NSURL *url = [NSURL fileURLWithPath:jbroot(@"/var") isDirectory:YES];
	return SAPResolveSymlink(url.URLByResolvingSymlinksInPath).path;
}

#pragma mark - Picker options

// Favorites and view options live in Safari's own container
// (Library/Preferences/com.qn.safaripicker.plist), separate from the tweak settings
static NSUserDefaults *SAPDefaults(void)
{
	static NSUserDefaults *defaults;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.qn.safaripicker"];
	});
	return defaults;
}

static NSString *const kSAPFavoriteFoldersKey = @"FavoriteFolders";
static NSString *const kSAPSortModeKey = @"SortMode";
static NSString *const kSAPGroupByKindKey = @"GroupByKind";
static NSString *const kSAPShowHiddenFilesKey = @"ShowHiddenFiles";
static NSString *const kSAPShowModificationDateKey = @"ShowModificationDate";

// On/off view options, with their defaults
static BOOL SAPOption(NSString *key)
{
	NSDictionary<NSString *, NSNumber *> *defaults = @{
		kSAPGroupByKindKey: @YES,
		kSAPShowHiddenFilesKey: @YES,
		kSAPShowModificationDateKey: @NO,
	};
	id value = [SAPDefaults() objectForKey:key] ?: defaults[key];
	return [value boolValue];
}

typedef NS_ENUM(NSInteger, SAPSortMode)
{
	SAPSortModeName,
	SAPSortModeType,
	SAPSortModeDate,
};

static SAPSortMode SAPCurrentSortMode(void)
{
	return (SAPSortMode)[SAPDefaults() integerForKey:kSAPSortModeKey];
}

#pragma mark - Favorites

static NSArray<NSString *> *SAPFavoritePaths(void)
{
	return [SAPDefaults() stringArrayForKey:kSAPFavoriteFoldersKey] ?: @[];
}

static BOOL SAPIsFavorite(NSString *path)
{
	return [SAPFavoritePaths() containsObject:path];
}

static void SAPSetFavorite(NSString *path, BOOL favorite)
{
	NSMutableArray<NSString *> *paths = [SAPFavoritePaths() mutableCopy];
	[paths removeObject:path];
	if(favorite)
	{
		[paths addObject:path];
	}
	[SAPDefaults() setObject:paths forKey:kSAPFavoriteFoldersKey];
}

static NSString *SAPDisplayName(NSString *path)
{
	return [path isEqualToString:@"/"] ? @"/" : path.lastPathComponent;
}

static UIAction *SAPCopyPathAction(NSString *title, NSString *path)
{
	return [UIAction actionWithTitle:title image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__kindof UIAction *action)
	{
		[UIPasteboard generalPasteboard].string = path;
	}];
}

#pragma mark - Listing

// Hidden = name starts with a dot. roothide's .jbroot-* link is always kept,
// it is the way into the jailbreak root from /var/mobile/Containers/Shared/AppGroup.
static BOOL SAPIsHiddenEntry(SAPFileEntry *entry)
{
	return [entry.name hasPrefix:@"."] && ![entry.name hasPrefix:@".jbroot-"];
}

// Folders stay on top in every mode
static NSArray<SAPFileEntry *> *SAPSortedEntries(NSArray<SAPFileEntry *> *entries, SAPSortMode mode)
{
	return [entries sortedArrayUsingComparator:^NSComparisonResult(SAPFileEntry *a, SAPFileEntry *b)
	{
		if(a.isDirectory != b.isDirectory)
		{
			return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
		}

		NSComparisonResult result = NSOrderedSame;
		if(mode == SAPSortModeType && !a.isDirectory)
		{
			result = [a.name.pathExtension localizedCaseInsensitiveCompare:b.name.pathExtension];
		}
		else if(mode == SAPSortModeDate)
		{
			// Newest first; entries without a date go last
			NSDate *dateA = a.modificationDate ?: [NSDate distantPast];
			NSDate *dateB = b.modificationDate ?: [NSDate distantPast];
			result = [dateB compare:dateA];
		}

		return result != NSOrderedSame ? result : [a.name localizedStandardCompare:b.name];
	}];
}

static NSString *SAPDetailText(SAPFileEntry *entry)
{
	static NSDateFormatter *formatter;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		formatter = [NSDateFormatter new];
		formatter.dateStyle = NSDateFormatterShortStyle;
		formatter.timeStyle = NSDateFormatterShortStyle;
	});

	NSMutableArray<NSString *> *parts = [NSMutableArray new];
	if(!entry.isDirectory && entry.fileSize)
	{
		[parts addObject:[NSByteCountFormatter stringFromByteCount:entry.fileSize.longLongValue countStyle:NSByteCountFormatterCountStyleFile]];
	}
	if(entry.modificationDate && SAPOption(kSAPShowModificationDateKey))
	{
		[parts addObject:[formatter stringFromDate:entry.modificationDate]];
	}
	return parts.count ? [parts componentsJoinedByString:@" · "] : nil;
}

// Finder-style kinds, in section order. Files are matched by extension (first match wins).
static NSArray<NSString *> *SAPKindOrder(void)
{
	return @[@"Folders", @"Images", @"Videos", @"Audio", @"Documents", @"Text", @"Archives", @"Other"];
}

static NSArray<NSArray *> *SAPKindTypes(void)
{
	static NSArray<NSArray *> *kindTypes;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSMutableArray<UTType *> *documentTypes = [@[UTTypePDF, UTTypePresentation, UTTypeSpreadsheet, UTTypeRTF] mutableCopy];
		for(NSString *identifier in @[@"org.openxmlformats.wordprocessingml.document", @"com.microsoft.word.doc", @"com.apple.iwork.pages.sffpages"])
		{
			UTType *type = [UTType typeWithIdentifier:identifier];
			if(type)
			{
				[documentTypes addObject:type];
			}
		}

		kindTypes = @[
			@[@"Images", @[UTTypeImage]],
			@[@"Videos", @[UTTypeMovie]],
			@[@"Audio", @[UTTypeAudio]],
			@[@"Documents", documentTypes],
			@[@"Text", @[UTTypeText, UTTypePropertyList, UTTypeJSON, UTTypeXML]],
			@[@"Archives", @[UTTypeArchive]],
		];
	});
	return kindTypes;
}

static NSString *SAPKindOfEntry(SAPFileEntry *entry)
{
	if(entry.isDirectory)
	{
		return @"Folders";
	}

	NSString *extension = entry.name.pathExtension.lowercaseString;
	// Package formats the system doesn't declare as archives
	if([@[@"deb", @"ipa", @"tipa"] containsObject:extension])
	{
		return @"Archives";
	}

	UTType *type = [UTType typeWithFilenameExtension:extension];
	for(NSArray *kindType in SAPKindTypes())
	{
		for(UTType *kindUTType in kindType[1])
		{
			if([type conformsToType:kindUTType])
			{
				return kindType[0];
			}
		}
	}
	return @"Other";
}

#pragma mark - View controller

@interface SAPFilePickerViewController () <UISearchResultsUpdating>
@property (nonatomic, strong) SAPFilePickerSession *session;
@property (nonatomic, strong, nullable) NSURL *directoryURL; // nil = start page
@property (nonatomic, copy) NSArray<SAPFileEntry *> *entries;
// Shown entries split into sections: one untitled section, or one per kind when grouping
@property (nonatomic, copy) NSArray<NSArray<SAPFileEntry *> *> *visibleSections;
@property (nonatomic, copy) NSArray<NSString *> *visibleSectionTitles;
@property (nonatomic, copy, nullable) NSString *loadError;
@property (nonatomic, strong) UIBarButtonItem *uploadItem;
@property (nonatomic, strong) UIBarButtonItem *folderMenuItem;
@property (nonatomic, copy, nullable) NSString *highlightName; // entry to reveal once shown
@property (nonatomic) CGFloat warningBannerWidth;
// Start page rows; rebuilt when the page appears (reads settings and resolves jbroot)
@property (nonatomic, copy) NSArray<NSDictionary *> *locations;
@end

@implementation SAPFilePickerViewController

+ (UINavigationController *)navigationControllerAllowingMultipleSelection:(BOOL)allowsMultipleSelection accessError:(NSString *)accessError completion:(SAPFilePickerCompletion)completion
{
	SAPFilePickerSession *session = [SAPFilePickerSession new];
	session.allowsMultipleSelection = allowsMultipleSelection;
	session.accessError = accessError;
	session.completion = completion;

	SAPFilePickerViewController *root = [[SAPFilePickerViewController alloc] initWithSession:session directoryURL:nil];
	return [[UINavigationController alloc] initWithRootViewController:root];
}

- (instancetype)initWithSession:(SAPFilePickerSession *)session directoryURL:(NSURL *)directoryURL
{
	if((self = [super initWithStyle:UITableViewStyleInsetGrouped]))
	{
		_session = session;
		_directoryURL = directoryURL;
	}
	return self;
}

- (void)viewDidLoad
{
	[super viewDidLoad];

	UIBarButtonItem *cancelItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
	if(self.directoryURL)
	{
		self.folderMenuItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:nil];
		self.navigationItem.rightBarButtonItems = @[cancelItem, self.folderMenuItem];
		[self updateFolderMenu];
	}
	else
	{
		self.navigationItem.rightBarButtonItem = cancelItem;
		self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Go to" style:UIBarButtonItemStylePlain target:self action:@selector(presentGoToPath)];
	}

	if(self.session.allowsMultipleSelection)
	{
		self.uploadItem = [[UIBarButtonItem alloc] initWithTitle:@"Upload" style:UIBarButtonItemStyleDone target:self action:@selector(uploadSelection)];
		self.toolbarItems = @[
			[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
			self.uploadItem,
		];
	}

	if(self.directoryURL)
	{
		self.title = SAPDisplayName(self.directoryURL.path);

		UISearchController *searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
		searchController.searchResultsUpdater = self;
		searchController.obscuresBackgroundDuringPresentation = NO;
		self.navigationItem.searchController = searchController;

		[self reloadEntries];
	}
	else
	{
		self.title = @"Local Files";
		[self reloadLocations];
	}
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];

	// Selection and favorites may have changed in a pushed folder
	[self.navigationController setToolbarHidden:!self.session.allowsMultipleSelection animated:animated];
	if(self.directoryURL)
	{
		// Sort / hidden files may have been changed from another folder's menu
		[self updateVisibleEntries];
	}
	else
	{
		[self reloadLocations];
		[self.tableView reloadData];
		// Settings may have changed while away: rebuild the banner on the next layout
		self.warningBannerWidth = 0;
		[self.view setNeedsLayout];
	}
	[self updateUploadItem];
	[self updateFolderMenu];
}

- (void)viewDidLayoutSubviews
{
	[super viewDidLayoutSubviews];

	CGFloat width = self.tableView.bounds.size.width;
	if(!self.directoryURL && width > 0 && width != self.warningBannerWidth)
	{
		self.warningBannerWidth = width;
		[self updateWarningBanner];
	}
}

// Red line on the start page while Safari can read the whole system
- (void)updateWarningBanner
{
	NSString *text = nil;
	if(SAPSystemFileAccessEnabled())
	{
		text = @"⚠️ System file access is ON";
	}
	else if(SAPSystemAccessGranted())
	{
		text = @"⚠️ System file access stays active until Safari is closed";
	}

	if(!text)
	{
		self.tableView.tableHeaderView = nil;
		return;
	}

	CGFloat width = self.tableView.bounds.size.width;
	UILabel *label = [UILabel new];
	label.text = text;
	label.textColor = [UIColor systemRedColor];
	label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	label.textAlignment = NSTextAlignmentCenter;
	label.numberOfLines = 0;

	CGSize size = [label sizeThatFits:CGSizeMake(width - 40, CGFLOAT_MAX)];
	UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, size.height + 20)];
	label.frame = CGRectMake(20, 12, width - 40, size.height);
	[container addSubview:label];
	self.tableView.tableHeaderView = container;
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	[self revealHighlightedEntry];
}

- (void)revealHighlightedEntry
{
	NSString *name = self.highlightName;
	self.highlightName = nil;
	if(!name)
	{
		return;
	}

	NSIndexPath *indexPath = nil;
	for(NSUInteger section = 0; section < self.visibleSections.count && !indexPath; section++)
	{
		NSUInteger row = [self.visibleSections[section] indexOfObjectPassingTest:^BOOL(SAPFileEntry *entry, NSUInteger idx, BOOL *stop)
		{
			return [entry.name isEqualToString:name];
		}];
		if(row != NSNotFound)
		{
			indexPath = [NSIndexPath indexPathForRow:row inSection:section];
		}
	}
	if(!indexPath)
	{
		return;
	}

	[self.tableView selectRowAtIndexPath:indexPath animated:YES scrollPosition:UITableViewScrollPositionMiddle];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[self.tableView deselectRowAtIndexPath:indexPath animated:YES];
	});
}

#pragma mark Go to path

- (void)presentGoToPath
{
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Go to Path"
		message:@"~ is /var/mobile. Paths not starting with / are relative to this folder."
		preferredStyle:UIAlertControllerStyleAlert];

	[alert addTextFieldWithConfigurationHandler:^(UITextField *textField)
	{
		textField.placeholder = @"/var/mobile/Documents";
		textField.text = self.directoryURL.path;
		textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
		textField.autocorrectionType = UITextAutocorrectionTypeNo;
		textField.spellCheckingType = UITextSpellCheckingTypeNo;
		textField.clearButtonMode = UITextFieldViewModeAlways;
		textField.returnKeyType = UIReturnKeyGo;
	}];

	__weak SAPFilePickerViewController *weakSelf = self;
	__weak UIAlertController *weakAlert = alert;
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	UIAlertAction *goAction = [UIAlertAction actionWithTitle:@"Go" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action)
	{
		[weakSelf goToPath:weakAlert.textFields.firstObject.text];
	}];
	[alert addAction:goAction];
	alert.preferredAction = goAction;

	[self presentViewController:alert animated:YES completion:nil];
}

- (void)goToPath:(NSString *)input
{
	NSString *path = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if(!path.length)
	{
		return;
	}

	if([path isEqualToString:@"~"] || [path hasPrefix:@"~/"])
	{
		path = [@"/var/mobile" stringByAppendingString:[path substringFromIndex:1]];
	}
	else if(!path.isAbsolutePath)
	{
		path = [(self.directoryURL.path ?: @"/") stringByAppendingPathComponent:path];
	}
	path = path.stringByStandardizingPath;

	NSURL *targetURL = SAPResolveSymlink([NSURL fileURLWithPath:path]);
	BOOL isDirectory = NO;
	BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:targetURL.path isDirectory:&isDirectory];

	if(exists && !isDirectory)
	{
		// A file: open its folder and point at it
		SAPFilePickerViewController *controller = [self pushDirectory:[NSURL fileURLWithPath:path.stringByDeletingLastPathComponent isDirectory:YES]];
		controller.highlightName = path.lastPathComponent;
		return;
	}

	// Missing or unreadable paths are still opened, so the folder's footer shows the exact error
	[self pushDirectory:targetURL];
}

- (void)reloadEntries
{
	NSError *error;
	self.entries = SAPEntriesAtURL(self.directoryURL, &error) ?: @[];
	self.loadError = self.entries.count || !error ? nil : SAPDescribeError(error);
	if(self.loadError)
	{
		SAPLog(@"Cannot list %@: %@", self.directoryURL.path, error);
	}
	[self updateVisibleEntries];
}

- (void)updateVisibleEntries
{
	NSArray<SAPFileEntry *> *entries = self.entries;

	if(!SAPOption(kSAPShowHiddenFilesKey))
	{
		entries = [entries filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SAPFileEntry *entry, NSDictionary *bindings)
		{
			return !SAPIsHiddenEntry(entry);
		}]];
	}

	NSString *query = self.navigationItem.searchController.searchBar.text;
	if(query.length)
	{
		entries = [entries filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@", query]];
	}

	NSArray<SAPFileEntry *> *sorted = SAPSortedEntries(entries, SAPCurrentSortMode());

	if(SAPOption(kSAPGroupByKindKey))
	{
		NSMutableDictionary<NSString *, NSMutableArray<SAPFileEntry *> *> *groups = [NSMutableDictionary new];
		for(SAPFileEntry *entry in sorted)
		{
			NSString *kind = SAPKindOfEntry(entry);
			if(!groups[kind])
			{
				groups[kind] = [NSMutableArray new];
			}
			[groups[kind] addObject:entry];
		}

		NSMutableArray *sections = [NSMutableArray new];
		NSMutableArray *titles = [NSMutableArray new];
		for(NSString *kind in SAPKindOrder())
		{
			if(groups[kind].count)
			{
				[sections addObject:groups[kind]];
				[titles addObject:kind];
			}
		}
		self.visibleSections = sections;
		self.visibleSectionTitles = titles;
	}
	else
	{
		self.visibleSections = @[sorted];
		self.visibleSectionTitles = @[@""];
	}

	[self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
	[self updateVisibleEntries];
}

- (void)updateUploadItem
{
	NSUInteger count = self.session.selectedURLs.count;
	self.uploadItem.enabled = count > 0;
	self.uploadItem.title = count ? [NSString stringWithFormat:@"Upload (%lu)", (unsigned long)count] : @"Upload";
}

- (void)updateFolderMenu
{
	if(!self.folderMenuItem)
	{
		return;
	}

	NSString *path = self.directoryURL.path;
	__weak SAPFilePickerViewController *weakSelf = self;

	UIAction *goToAction = [UIAction actionWithTitle:@"Go to Path…" image:[UIImage systemImageNamed:@"arrow.right.circle"] identifier:nil handler:^(__kindof UIAction *action)
	{
		[weakSelf presentGoToPath];
	}];

	UIAction *startPageAction = [UIAction actionWithTitle:@"Start Page" image:[UIImage systemImageNamed:@"house"] identifier:nil handler:^(__kindof UIAction *action)
	{
		[weakSelf.navigationController popToRootViewControllerAnimated:YES];
	}];

	UIMenu *folderActions = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline
		children:@[startPageAction, [self favoriteActionForPath:path], SAPCopyPathAction(@"Copy Path", path), goToAction]];
	self.folderMenuItem.menu = [UIMenu menuWithChildren:@[folderActions, [self viewMenu]]];
}

- (UIMenu *)viewMenu
{
	__weak SAPFilePickerViewController *weakSelf = self;
	SAPSortMode currentMode = SAPCurrentSortMode();

	NSArray *sortModes = @[
		@[@(SAPSortModeName), @"Name", @"textformat"],
		@[@(SAPSortModeType), @"Type", @"doc.text"],
		@[@(SAPSortModeDate), @"Date Modified", @"calendar"],
	];
	NSMutableArray<UIMenuElement *> *sortActions = [NSMutableArray new];
	for(NSArray *sortMode in sortModes)
	{
		SAPSortMode mode = [sortMode[0] integerValue];
		UIAction *action = [UIAction actionWithTitle:sortMode[1] image:[UIImage systemImageNamed:sortMode[2]] identifier:nil handler:^(__kindof UIAction *a)
		{
			[SAPDefaults() setInteger:mode forKey:kSAPSortModeKey];
			[weakSelf updateVisibleEntries];
			[weakSelf updateFolderMenu];
		}];
		action.state = mode == currentMode ? UIMenuElementStateOn : UIMenuElementStateOff;
		[sortActions addObject:action];
	}
	UIMenu *sortMenu = [UIMenu menuWithTitle:@"Sort By" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:sortActions];

	UIMenu *optionsMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
		[self optionActionWithTitle:@"Group by Kind" image:@"square.grid.2x2" key:kSAPGroupByKindKey],
		[self optionActionWithTitle:@"Show Hidden Files" image:@"eye" key:kSAPShowHiddenFilesKey],
		[self optionActionWithTitle:@"Show Date Modified" image:@"clock" key:kSAPShowModificationDateKey],
	]];

	return [UIMenu menuWithTitle:@"View" image:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"] identifier:nil options:0 children:@[sortMenu, optionsMenu]];
}

- (UIAction *)optionActionWithTitle:(NSString *)title image:(NSString *)imageName key:(NSString *)key
{
	BOOL enabled = SAPOption(key);
	__weak SAPFilePickerViewController *weakSelf = self;
	UIAction *action = [UIAction actionWithTitle:title image:[UIImage systemImageNamed:imageName] identifier:nil handler:^(__kindof UIAction *a)
	{
		[SAPDefaults() setBool:!enabled forKey:key];
		[weakSelf updateVisibleEntries];
		[weakSelf updateFolderMenu];
	}];
	action.state = enabled ? UIMenuElementStateOn : UIMenuElementStateOff;
	return action;
}

- (void)cancel
{
	[self.session finishWithURLs:nil];
}

- (void)uploadSelection
{
	[self.session finishWithURLs:self.session.selectedURLs.array];
}

#pragma mark Start page

typedef NS_ENUM(NSInteger, SAPStartSection)
{
	SAPStartSectionFavorites,
	SAPStartSectionLocations,
};

- (void)reloadLocations
{
	NSMutableArray<NSDictionary *> *locations = [NSMutableArray new];
	if(SAPSystemFileAccessEnabled())
	{
		[locations addObject:@{ @"title": @"Root File System", @"path": @"/", @"icon": @"internaldrive" }];
	}
	[locations addObject:@{ @"title": @"Mobile", @"path": @"/var/mobile", @"icon": @"person.crop.circle" }];
	[locations addObject:@{ @"title": @"Jailbreak var", @"path": SAPJailbreakVarPath(), @"icon": @"lock.open" }];
	self.locations = locations;
}

// The favorites section is hidden while empty
- (SAPStartSection)startSectionAtIndex:(NSInteger)index
{
	return SAPFavoritePaths().count ? (SAPStartSection)index : SAPStartSectionLocations;
}

// Path a start page row opens
- (NSString *)startPathAtIndexPath:(NSIndexPath *)indexPath
{
	if([self startSectionAtIndex:indexPath.section] == SAPStartSectionFavorites)
	{
		return SAPFavoritePaths()[indexPath.row];
	}
	return self.locations[indexPath.row][@"path"];
}

#pragma mark Table view

- (SAPFileEntry *)entryAtIndexPath:(NSIndexPath *)indexPath
{
	return self.visibleSections[indexPath.section][indexPath.row];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	if(self.directoryURL)
	{
		// Keep one section when empty so the footer (error / "Empty folder") still shows
		return MAX(self.visibleSections.count, (NSUInteger)1);
	}
	return SAPFavoritePaths().count ? 2 : 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	if(self.directoryURL)
	{
		return section < (NSInteger)self.visibleSections.count ? self.visibleSections[section].count : 0;
	}
	return [self startSectionAtIndex:section] == SAPStartSectionFavorites ? SAPFavoritePaths().count : self.locations.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
	if(self.directoryURL)
	{
		NSString *title = section < (NSInteger)self.visibleSectionTitles.count ? self.visibleSectionTitles[section] : nil;
		return title.length ? title : nil;
	}
	return [self startSectionAtIndex:section] == SAPStartSectionFavorites ? @"Favorites" : @"Locations";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
	if(!self.directoryURL)
	{
		if([self startSectionAtIndex:section] != SAPStartSectionLocations)
		{
			return nil;
		}
		if(self.session.accessError)
		{
			return self.session.accessError;
		}
		return SAPSystemFileAccessEnabled() ? nil : @"Read only\nSome folders stay blocked by default; this can be changed in Settings › SafariPicker.";
	}
	if(section != [self numberOfSectionsInTableView:tableView] - 1)
	{
		return nil;
	}
	if(self.loadError)
	{
		return [NSString stringWithFormat:@"Cannot read %@: %@", self.directoryURL.path, self.loadError];
	}
	return self.entries.count ? nil : @"Empty folder";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
	if(!cell)
	{
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
	}

	UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
	content.secondaryTextProperties.color = [UIColor secondaryLabelColor];
	content.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;

	if(!self.directoryURL)
	{
		NSString *path = [self startPathAtIndexPath:indexPath];
		if([self startSectionAtIndex:indexPath.section] == SAPStartSectionFavorites)
		{
			content.text = SAPDisplayName(path);
			content.image = [UIImage systemImageNamed:@"star.fill"];
		}
		else
		{
			NSDictionary *location = self.locations[indexPath.row];
			content.text = location[@"title"];
			content.image = [UIImage systemImageNamed:location[@"icon"]];
		}
		content.secondaryText = path;
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		cell.contentConfiguration = content;
		return cell;
	}

	SAPFileEntry *entry = [self entryAtIndexPath:indexPath];
	content.text = entry.name;
	content.textProperties.numberOfLines = 1;
	content.textProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;

	if(entry.isDirectory)
	{
		NSString *icon = entry.isSymbolicLink ? @"folder.badge.questionmark" : @"folder.fill";
		if(SAPIsFavorite(entry.targetURL.path))
		{
			icon = @"star.fill";
		}
		content.image = [UIImage systemImageNamed:icon];
		content.secondaryText = entry.isSymbolicLink ? [@"→ " stringByAppendingString:entry.linkTargetURL.path] : SAPDetailText(entry);
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	}
	else
	{
		content.image = [UIImage systemImageNamed:@"doc"];
		content.secondaryText = SAPDetailText(entry);
		cell.accessoryType = [self.session.selectedURLs containsObject:entry.targetURL] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	}

	cell.contentConfiguration = content;
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];

	if(!self.directoryURL)
	{
		[self pushDirectory:[NSURL fileURLWithPath:[self startPathAtIndexPath:indexPath] isDirectory:YES]];
		return;
	}

	SAPFileEntry *entry = [self entryAtIndexPath:indexPath];
	if(entry.isDirectory)
	{
		[self pushDirectory:entry.targetURL];
		return;
	}

	if(!self.session.allowsMultipleSelection)
	{
		[self.session finishWithURLs:@[entry.targetURL]];
		return;
	}

	if([self.session.selectedURLs containsObject:entry.targetURL])
	{
		[self.session.selectedURLs removeObject:entry.targetURL];
	}
	else
	{
		[self.session.selectedURLs addObject:entry.targetURL];
	}
	[tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
	[self updateUploadItem];
}

#pragma mark Row actions

- (UIAction *)favoriteActionForPath:(NSString *)path
{
	BOOL favorite = SAPIsFavorite(path);
	__weak SAPFilePickerViewController *weakSelf = self;
	return [UIAction actionWithTitle:favorite ? @"Remove from Favorites" : @"Add to Favorites"
		image:[UIImage systemImageNamed:favorite ? @"star.slash" : @"star"]
		identifier:nil
		handler:^(__kindof UIAction *action)
	{
		SAPSetFavorite(path, !favorite);
		[weakSelf.tableView reloadData];
		[weakSelf updateFolderMenu];
	}];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
	NSMutableArray<UIMenuElement *> *actions = [NSMutableArray new];

	if(!self.directoryURL)
	{
		NSString *path = [self startPathAtIndexPath:indexPath];
		[actions addObject:[self favoriteActionForPath:path]];
		[actions addObject:SAPCopyPathAction(@"Copy Path", path)];
	}
	else
	{
		SAPFileEntry *entry = [self entryAtIndexPath:indexPath];
		if(entry.isDirectory)
		{
			[actions addObject:[self favoriteActionForPath:entry.targetURL.path]];
		}
		[actions addObject:SAPCopyPathAction(@"Copy Path", entry.url.path)];
		if(entry.isSymbolicLink)
		{
			[actions addObject:SAPCopyPathAction(@"Copy Link Target Path", entry.linkTargetURL.path)];
		}
	}

	return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions)
	{
		return [UIMenu menuWithChildren:actions];
	}];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
	if(self.directoryURL || [self startSectionAtIndex:indexPath.section] != SAPStartSectionFavorites)
	{
		return nil;
	}

	NSString *path = [self startPathAtIndexPath:indexPath];
	__weak SAPFilePickerViewController *weakSelf = self;
	UIContextualAction *removeAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Remove"
		handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL))
	{
		SAPSetFavorite(path, NO);
		[weakSelf.tableView reloadData];
		completionHandler(YES);
	}];
	return [UISwipeActionsConfiguration configurationWithActions:@[removeAction]];
}

- (SAPFilePickerViewController *)pushDirectory:(NSURL *)url
{
	SAPFilePickerViewController *controller = [[SAPFilePickerViewController alloc] initWithSession:self.session directoryURL:url];
	[self.navigationController pushViewController:controller animated:YES];
	return controller;
}

@end
