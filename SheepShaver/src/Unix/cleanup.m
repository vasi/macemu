#include "debug.h"

#include <dirent.h>
#import <Foundation/Foundation.h>

// FIXME: header
void hdiutil_detach(NSString *dev);
NSString *hdiutil_find_attached(NSString *drive_id);


// Close all file descriptors, so they don't keep any locks open
static void cleanup_close_fds() {
	int high = -1;
	DIR *dir = opendir("/dev/fd");
	struct dirent *ent = NULL;
	while ((ent = readdir(dir))) {
		if (ent->d_name[0] == '.')
			continue;
		int v = atoi(ent->d_name);
		if (v > high)
			high = v;
	}
	closedir(dir);
	for (int i = 0; i <= high; ++i) {
		if (i != STDIN_FILENO && i != STDOUT_FILENO) {
			close(i);
		}
	}
}


int main(void) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	cleanup_close_fds();
	setsid(); // Don't get SIGINT!
	D(bug("Starting cleanup process\n"));
	
	// Read drive IDs from SheepShaver
	NSData *data = [[NSFileHandle fileHandleWithStandardInput]
    readDataToEndOfFile];
	D(bug("SheepShaver quit!\n"));
	
	// Ensure we're all unmounted
	const char *bytes = [data bytes], *end = bytes + [data length];
	while (true) {
		const char *z = memchr(bytes, '\0', end - bytes);
		if (!z)
			break;
		NSString *drive = [NSString stringWithUTF8String: bytes];
		bytes = z + 1;
		
    D(bug("Looking for drive %s...", [drive UTF8String]));
		NSLog(@"Looking for %@...", drive);
		NSString *dev = hdiutil_find_attached(drive);
		if (dev) {
      D(bug("Detaching disk %s!", [dev UTF8String]));
			hdiutil_detach(dev);
		}
	}
	
	[pool release];
	return 0;
}
