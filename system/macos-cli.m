#import <Cocoa/Cocoa.h>

#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>

#include "macos-request.h"

/*
 * The diffotron command, installed in Diff-o-tron.app/Contents/Helpers: opens
 * two files or folders in Diff-o-tron, as `git difftool` does.
 */

static NSString* const kBundleIdentifier = @"com.srgpqt.diff-o-tron";

/* How long to wait for the app to open the request. */
static const int64_t kOpenTimeout = 60;

static const char* const kUsage =
	"usage: diffotron [-w | --wait] [-v | --verbose] [-L | --label LABEL]... PATH_A PATH_B\n"
	"\n"
	"Compare two files or folders in Diff-o-tron.\n"
	"\n"
	"  -w, --wait         wait until the comparison is closed\n"
	"  -v, --verbose      describe what's happening\n"
	"  -L, --label LABEL  show LABEL instead of a path's name: given once for both\n"
	"                     sides, or twice for A then B\n"
	"\n"
	"To use it with git difftool, add this to ~/.gitconfig:\n"
	"\n"
	"  [diff]\n"
	"      tool = diffotron\n"
	"  [difftool]\n"
	"      prompt = false\n"
	"  [difftool \"diffotron\"]\n"
	"      cmd = diffotron --wait --label \\\"$MERGED\\\" \\\"$LOCAL\\\" \\\"$REMOTE\\\"\n";

static NSURL* g_request_dir = nil;
static NSMutableArray* g_sources = nil;
static BOOL g_opened = NO;
static BOOL g_verbose = NO;

static void note(NSString* message) {
	if (g_verbose) fprintf(stderr, "diffotron: %s\n", message.UTF8String);
}

static void finish(int status) {
	if (g_request_dir) [[NSFileManager defaultManager] removeItemAtURL:g_request_dir error:NULL];
	exit(status);
}

static void fail(NSString* message) {
	fprintf(stderr, "diffotron: %s\n", message.UTF8String);
	finish(1);
}

static NSString* arg_string(const char* arg) {
	NSString* string = [NSString stringWithUTF8String:arg];
	return string ? string : [NSString stringWithCString:arg encoding:NSISOLatin1StringEncoding];
}

/* The app this command is in, or else the installed one. */
static NSURL* app_url(void) {
	char path[PATH_MAX];
	char resolved[PATH_MAX];
	uint32_t size = sizeof path;
	if (_NSGetExecutablePath(path, &size) == 0 && realpath(path, resolved)) {
		NSURL* url = [NSURL fileURLWithFileSystemRepresentation:resolved isDirectory:NO relativeToURL:nil];
		NSURL* app = url.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
		if ([app.pathExtension isEqualToString:@"app"]) return app;
	}
	return [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:kBundleIdentifier];
}

/*
 * The files the app must be able to read besides the compared paths: the
 * targets of the symlinks in compared folders, as `git difftool --dir-diff`
 * makes for working tree files.
 */
static NSArray<NSURL*>* symlink_targets(NSURL* url) {
	NSMutableArray<NSURL*>* targets = [NSMutableArray array];
	NSDirectoryEnumerator* enumerator = [[NSFileManager defaultManager]
		enumeratorAtURL:url
		includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey]
		options:0
		errorHandler:nil];
	for (NSURL* item in enumerator) {
		NSNumber* isLink = nil;
		[item getResourceValue:&isLink forKey:NSURLIsSymbolicLinkKey error:NULL];
		if (!isLink.boolValue) continue;
		NSURL* target = item.URLByResolvingSymlinksInPath;
		NSNumber* isFile = nil;
		[target getResourceValue:&isFile forKey:NSURLIsRegularFileKey error:NULL];
		if (isFile.boolValue) [targets addObject:target];
	}
	return targets;
}

/* Watch for the app quitting before it closes the comparison. */
static void watch_process(pid_t pid) {
	dispatch_source_t source = dispatch_source_create(
		DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
	dispatch_source_set_event_handler(source, ^(void) {
		note(@"Diff-o-tron quit");
		if (!g_opened) fail(@"Diff-o-tron quit before opening the comparison");
		finish(0);
	});
	dispatch_resume(source);
	[g_sources addObject:source];
}

/* Clean up when interrupted, as when git difftool is. */
static void handle_signal(int signal_number) {
	signal(signal_number, SIG_IGN);
	dispatch_source_t source = dispatch_source_create(
		DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)signal_number, 0, dispatch_get_main_queue());
	dispatch_source_set_event_handler(source, ^(void) {
		finish(128 + signal_number);
	});
	dispatch_resume(source);
	[g_sources addObject:source];
}

int main(int argc, const char* argv[]) {
	@autoreleasepool {
		g_sources = [NSMutableArray array];
		BOOL wait = NO;
		NSMutableArray<NSString*>* labels = [NSMutableArray array];
		NSMutableArray<NSString*>* paths = [NSMutableArray array];

		BOOL options = YES;
		for (int i = 1; i < argc; i++) {
			NSString* arg = arg_string(argv[i]);
			if (options && [arg isEqualToString:@"--"]) {
				options = NO;
			} else if (options && ([arg isEqualToString:@"-w"] || [arg isEqualToString:@"--wait"])) {
				wait = YES;
			} else if (options && ([arg isEqualToString:@"-v"] || [arg isEqualToString:@"--verbose"])) {
				g_verbose = YES;
			} else if (options && ([arg isEqualToString:@"-L"] || [arg isEqualToString:@"--label"])) {
				if (++i >= argc) {
					fputs(kUsage, stderr);
					return 2;
				}
				[labels addObject:arg_string(argv[i])];
			} else if (options && ([arg isEqualToString:@"-h"] || [arg isEqualToString:@"--help"])) {
				fputs(kUsage, stdout);
				return 0;
			} else if (options && arg.length > 1 && [arg hasPrefix:@"-"]) {
				fprintf(stderr, "diffotron: unknown option %s\n\n%s", argv[i], kUsage);
				return 2;
			} else {
				[paths addObject:arg];
			}
		}
		if (paths.count != 2 || labels.count > 2) {
			fputs(kUsage, stderr);
			return 2;
		}
		if (labels.count == 1) [labels addObject:labels[0]];
		while (labels.count < 2) [labels addObject:@""];

		/* git difftool passes paths relative to the top of the working tree, where it runs. */
		NSMutableArray<NSURL*>* urls = [NSMutableArray array];
		NSMutableArray<NSString*>* absolutePaths = [NSMutableArray array];
		for (NSString* path in paths) {
			NSURL* url = [NSURL fileURLWithPath:path].URLByStandardizingPath;
			if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
				fail([NSString stringWithFormat:@"%@: No such file or directory", path]);
			}
			[absolutePaths addObject:url.path];
			/* Not devices such as /dev/null, which the app can read anyway. */
			NSNumber* isFile = nil;
			NSNumber* isDirectory = nil;
			[url getResourceValue:&isFile forKey:NSURLIsRegularFileKey error:NULL];
			[url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
			if (isFile.boolValue || isDirectory.boolValue) [urls addObject:url];
			if (isDirectory.boolValue) [urls addObjectsFromArray:symlink_targets(url)];
			NSURL* resolved = url.URLByResolvingSymlinksInPath;
			if (isFile.boolValue && ![resolved isEqual:url]) [urls addObject:resolved];
		}

		NSURL* app = app_url();
		if (!app) fail(@"Diff-o-tron isn't installed");

		NSString* dirTemplate = [NSTemporaryDirectory() stringByAppendingPathComponent:@"diffotron.XXXXXX"];
		char* dir = strdup(dirTemplate.fileSystemRepresentation);
		if (!dir || !mkdtemp(dir)) fail(@"Can't create a temporary directory");
		g_request_dir = [NSURL fileURLWithFileSystemRepresentation:dir isDirectory:YES relativeToURL:nil];
		free(dir);

		NSString* token = [NSUUID UUID].UUIDString;
		NSDictionary* request = @{
			kRequestPaths: absolutePaths,
			kRequestLabels: labels,
			kRequestToken: token,
			kRequestWait: @(wait)
		};
		NSURL* requestURL = [g_request_dir URLByAppendingPathComponent:[@"comparison" stringByAppendingPathExtension:kRequestExtension]];
		NSError* error = nil;
		if (![request writeToURL:requestURL error:&error]) fail(error.localizedDescription);
		[urls insertObject:requestURL atIndex:0];

		handle_signal(SIGINT);
		handle_signal(SIGTERM);
		handle_signal(SIGHUP);

		NSDistributedNotificationCenter* center = [NSDistributedNotificationCenter defaultCenter];
		[center addObserverForName:kOpenedNotification object:token queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification* notification) {
			note(@"Diff-o-tron opened the comparison");
			g_opened = YES;
			if (!wait) finish(0);
		}];
		[center addObserverForName:kClosedNotification object:token queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification* notification) {
			note(@"Diff-o-tron closed the comparison");
			finish(0);
		}];

		note([NSString stringWithFormat:@"Opening %@ with %@", [urls valueForKey:@"path"], app.path]);

		NSWorkspaceOpenConfiguration* configuration = [NSWorkspaceOpenConfiguration configuration];
		[[NSWorkspace sharedWorkspace]
			openURLs:urls
			withApplicationAtURL:app
			configuration:configuration
			completionHandler:^(NSRunningApplication* running, NSError* openError) {
				dispatch_async(dispatch_get_main_queue(), ^(void) {
					if (!running) fail(openError ? openError.localizedDescription : @"Can't open Diff-o-tron");
					note([NSString stringWithFormat:@"Opened with %@ (pid %d)", running.bundleURL.path, running.processIdentifier]);
					watch_process(running.processIdentifier);
				});
			}];

		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kOpenTimeout * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^(void) {
			if (!g_opened) fail(@"Diff-o-tron didn't open the comparison");
		});

		CFRunLoopRun();
	}
	return 0;
}
