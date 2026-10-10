#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSControlTableCell.h>
#import "SAPPrefs.h"
#import <roothide.h>
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;

@interface SAPRootListController : PSListController
// The Dangerous group, only shown while Upload Any File is on
@property (nonatomic, copy) NSArray<PSSpecifier *> *uploadSpecifiers;
@end

@implementation SAPRootListController

- (NSArray *)specifiers
{
	if(!_specifiers)
	{
		NSMutableArray<PSSpecifier *> *specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
		self.uploadSpecifiers = [specifiers filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(PSSpecifier *specifier, NSDictionary *bindings)
		{
			return [[specifier propertyForKey:@"requiresUpload"] boolValue];
		}]];
		if(!SAPPrefBool(kSAPPrefUploadAnyFile))
		{
			[specifiers removeObjectsInArray:self.uploadSpecifiers];

			// Left over from versions where Upload Any File defaulted to on: the switch is hidden
			// now, so don't keep sandyd's flag file around
			if(SAPPrefBool(kSAPPrefSystemFileAccess))
			{
				[self saveValue:@NO forKey:kSAPPrefSystemFileAccess specifier:nil];
			}
		}
		_specifiers = specifiers;
	}
	return _specifiers;
}

// Values live in a plain plist in the jailbreak root (see SAPPrefs.m) instead of cfprefsd,
// so Safari can read the same file directly
- (id)readPreferenceValue:(PSSpecifier *)specifier
{
	NSString *key = [specifier propertyForKey:@"key"];
	return SAPReadPrefs()[key] ?: SAPPrefsDefaults()[key] ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier
{
	NSString *key = [specifier propertyForKey:@"key"];

	if([key isEqualToString:kSAPPrefSystemFileAccess] && [value boolValue])
	{
		[self confirmSystemFileAccessForSpecifier:specifier];
		return;
	}

	BOOL saved = [self saveValue:value forKey:key specifier:specifier];
	if(!saved)
	{
		return;
	}

	if([key isEqualToString:kSAPPrefSystemFileAccess])
	{
		// Access Safari already got stays until it is closed
		[self closeSafari];
	}
	else if([key isEqualToString:kSAPPrefUploadAnyFile])
	{
		[self updateUploadSpecifiers:[value boolValue]];
	}
}

- (void)updateUploadSpecifiers:(BOOL)uploadEnabled
{
	BOOL shown = [_specifiers containsObject:self.uploadSpecifiers.firstObject];

	if(uploadEnabled && !shown)
	{
		[self insertContiguousSpecifiers:self.uploadSpecifiers atIndex:_specifiers.count animated:YES];
	}
	else if(!uploadEnabled && shown)
	{
		[self removeContiguousSpecifiers:self.uploadSpecifiers animated:YES];

		// System access only exists for the picker; don't leave sandyd's flag file behind
		if(SAPPrefBool(kSAPPrefSystemFileAccess))
		{
			if([self saveValue:@NO forKey:kSAPPrefSystemFileAccess specifier:nil])
			{
				[self closeSafari];
			}
		}
	}
}

- (void)confirmSystemFileAccessForSpecifier:(PSSpecifier *)specifier
{
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Allow System File Access?"
		message:@"Safari will be able to read every file on this device, including other apps' data, after the upload file picker is opened. A website exploiting a Safari bug could read them too.\n\nOnly turn this on while you need it."
		preferredStyle:UIAlertControllerStyleAlert];

	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action)
	{
		// The switch already moved; put it back
		[self reloadSpecifier:specifier animated:YES];
	}]];

	[alert addAction:[UIAlertAction actionWithTitle:@"Allow" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action)
	{
		[self saveValue:@YES forKey:kSAPPrefSystemFileAccess specifier:specifier];
	}]];

	// Not required when turning it on (Safari picks it up the next time the picker opens),
	// offered so Safari starts from a clean state
	[alert addAction:[UIAlertAction actionWithTitle:@"Allow & Close Safari" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action)
	{
		if([self saveValue:@YES forKey:kSAPPrefSystemFileAccess specifier:specifier])
		{
			[self showMessage:[self terminateSafari]];
		}
	}]];

	[self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)saveValue:(id)value forKey:(NSString *)key specifier:(PSSpecifier *)specifier
{
	NSMutableDictionary *prefs = [SAPReadPrefs() mutableCopy];
	prefs[key] = value;

	NSString *path = SAPPrefsFilePath();
	[[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];

	BOOL saved = [prefs writeToFile:path atomically:YES];
	if(saved && [key isEqualToString:kSAPPrefSystemFileAccess])
	{
		saved = [self setSystemAccessFlag:[value boolValue]];
	}

	if(!saved)
	{
		if(specifier)
		{
			[self reloadSpecifier:specifier animated:YES];
		}
		UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Could not save setting" message:path preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
	}
	return saved;
}

// sandyd only grants SafariPicker_SystemAccess while this file exists
- (BOOL)setSystemAccessFlag:(BOOL)enabled
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
	if(enabled)
	{
		return [fileManager fileExistsAtPath:kSAPSystemAccessFlagPath] || [[NSData data] writeToFile:kSAPSystemAccessFlagPath atomically:YES];
	}
	return ![fileManager fileExistsAtPath:kSAPSystemAccessFlagPath] || [fileManager removeItemAtPath:kSAPSystemAccessFlagPath error:nil];
}

#pragma mark Close Safari

// The Close Safari button, and after System File Access is turned off
- (void)closeSafari
{
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Close Safari?" message:nil
		preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action)
	{
		[self showMessage:[self terminateSafari]];
	}]];
	[self presentViewController:alert animated:YES completion:nil];
}

// Uses the jailbreak's killall, like the Respring buttons of other tweaks
- (NSString *)terminateSafari
{
	NSString *fallback = @"Could not close Safari from here. Close it from the app switcher instead.";

	NSString *killall = jbroot(@"/usr/bin/killall");
	if(![[NSFileManager defaultManager] isExecutableFileAtPath:killall])
	{
		return fallback;
	}

	pid_t pid;
	const char *argv[] = { killall.fileSystemRepresentation, "MobileSafari", NULL };
	if(posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, environ) != 0)
	{
		return fallback;
	}

	int status = 0;
	if(waitpid(pid, &status, 0) < 0 || !WIFEXITED(status))
	{
		return fallback;
	}

	switch(WEXITSTATUS(status))
	{
		case 0:
			return @"Safari was closed.";
		case 1:
			// killall found no matching process
			return @"Safari was not running.";
		default:
			return fallback;
	}
}

- (void)showMessage:(NSString *)message
{
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];

	PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
	BOOL dangerous = [[specifier propertyForKey:@"key"] isEqualToString:kSAPPrefSystemFileAccess];
	cell.textLabel.textColor = dangerous ? [UIColor systemRedColor] : [UIColor labelColor];
	if([cell isKindOfClass:[PSControlTableCell class]])
	{
		UIControl *control = ((PSControlTableCell *)cell).control;
		if([control isKindOfClass:[UISwitch class]])
		{
			((UISwitch *)control).onTintColor = dangerous ? [UIColor systemRedColor] : nil;
		}
	}

	return cell;
}

@end
