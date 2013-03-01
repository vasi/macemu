/*
 *  disk_hdiutil_macosx.mm - Apple disk image implementation
 *
 *  Basilisk II (C) Dave Vasilevsky
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#include "disk_unix.h"

#include <paths.h> // _PATH_DEV
#include <sys/param.h> // MAX

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOBSD.h>
#import <IOKit/storage/IOMedia.h>


// TODO
// - Check magic?
// - Restore sparsebundle driver
// - Test crashing
// - Shadow disks


// Key in IORegistry for unique of an attached image
static const CFStringRef DriveIdentifierKey =
	 CFSTR("hdiagent-drive-identifier");

// Key to indicate that a bundle is a disk image
static NSString *ImageBundleKey = @"diskimage-bundle-type";

// Raw disk image identifier
static NSString *ImageTypeRaw = @"RAW*";

// Path to hdiutil
static const char *HdiutilPath = "/usr/bin/hdiutil";


// Pipe to communicate with cleanup process
static int cleanup_fd = -1;


extern "C" {
// Detach a disk image
void hdiutil_detach(NSString *dev);

// Find the device corresponding to a unique drive ID
NSString *hdiutil_find_attached(NSString *drive_id);
}

// Run hdiutil and return the plist output, or NULL on failure.
static id hdiutil(NSArray *args);

// Attach a disk image, returning the full dev path, or NULL on failure.
static NSString *attach(NSArray *image_args, bool read_only);

// Does this look like a bundled image?
// SheepShaver's default raw file disk implementation will deal ok with a
// locked file, but not a locked bundle. We have to claim them as our own,
// and refuse to mount them.
static bool is_bundle_image(NSString *path, NSString **lockfile);

// Is this an image we can use? Return whether it's shared (mounted by someone
// else), and what arguments to use for mounting it.
static disk_generic_status is_usable(NSString *path, NSArray **attach_args,
	bool *shared);

// Get information about a mounted image from the IO registry,
// return true on success.
static bool image_info(NSString *dev, NSString **drive_id, bool *read_only,
	loff_t *size);

// Get just the device name (BSD name) part of a device path: /dev/foo => foo
static NSString *dev_name(NSString *dev);

// Ensure a disk is unmounted cleanly, even if we crash
static void queue_for_cleanup(NSString *drive_id);



struct disk_hdiutil : disk_generic {
	disk_hdiutil(NSString *dev, int fd, bool read_only, loff_t size,
		bool shared)
	: dev([dev retain]), fd(fd), read_only(read_only), shared(shared),
		total_size(size) { }
	
	virtual ~disk_hdiutil() {
		close(fd);
		if (!shared)
			hdiutil_detach(dev);
		[dev release];
	}
	
	virtual bool is_read_only() { return read_only; }
	virtual loff_t size() { return total_size; }
	
	virtual size_t read(void *buf, loff_t offset, size_t length) {
		return pread(fd, buf, length, offset);
	}
	
	virtual size_t write(void *buf, loff_t offset, size_t length) {
		return pwrite(fd, buf, length, offset);
	}
	
protected:
	NSString *dev;
	int fd;
	bool read_only;
	bool shared;
	loff_t total_size;
};


static id hdiutil(NSArray *args) {
	// Setup the hdiutil process
	NSTask *task = [[[NSTask alloc] init] autorelease];
	[task setLaunchPath: [NSString stringWithUTF8String: HdiutilPath]];
	[task setArguments: args];
	NSPipe *pipe = [NSPipe pipe];
	[task setStandardOutput: pipe];
	[task setStandardError: [NSFileHandle fileHandleWithNullDevice]];
	
	// Launch it, and wait for return
	[task launch];
	NSFileHandle *fh = [pipe fileHandleForReading];
	NSData *output = [fh readDataToEndOfFile];
	[task waitUntilExit];
	
	// Check for successful return
	if ([task terminationStatus] != 0)
		return nil;
	
	// Build a plist from the output
	NSString *error = nil;
	id plist = [NSPropertyListSerialization propertyListFromData: output
		mutabilityOption: NSPropertyListImmutable format: NULL
		errorDescription: &error];
	return error ? nil : plist;
}

static NSString *attach(NSArray *image_args, bool read_only) {
	// Setup arguments
	NSMutableArray *args = [NSMutableArray arrayWithObjects:
		@"attach", @"-nomount", @"-noverify", @"-plist", nil];
	if (read_only)
		[args addObject: @"-readonly"];
	[args addObjectsFromArray: image_args];
	
	// We may get multiple entries, take the minimum (in this case, shortest),
	// which will be the whole disk.
	id plist = hdiutil(args);
	NSString *dev = [plist valueForKeyPath: @"system-entities.@min.dev-entry"];
	if (!dev)
		return nil;
	
	if (!dev_name(dev)) // Ensure it's a /dev device
		return nil;
	return dev;
}

void hdiutil_detach(NSString *dev) {
	hdiutil([NSArray arrayWithObjects: @"detach", dev, nil]);
}

static bool is_bundle_image(NSString *path, NSString **lockfile) {
	// Look for a plist, with the right key
	NSString *info = [path stringByAppendingPathComponent: @"Info.plist"];
	NSData *data = [NSData dataWithContentsOfFile: info];
	if (!data)
		return false;
	
	NSString *error = NULL;
	id plist = [NSPropertyListSerialization propertyListFromData: data
		mutabilityOption: NSPropertyListImmutable format: NULL
		errorDescription: &error];
	if (!plist)
		return false;
	if (![plist valueForKeyPath: ImageBundleKey])
		return false;
	
	// Check for a lockfile
	NSString *token = [path stringByAppendingPathComponent: @"token"];
	if (lockfile && [[NSFileManager defaultManager] fileExistsAtPath: token])
		*lockfile = token;
	return true;
}

static disk_generic_status is_usable(NSString *path, NSArray **attach_args,
		bool *shared) {
	// Check for recognized formats
	NSString *lockfile = path;
	bool recognized = is_bundle_image(path, &lockfile);
	
	// This checks both the format, and whether the disk is locked or in-use
	id plist = hdiutil([NSArray arrayWithObjects:
		@"imageinfo", @"-format", @"-plist", path, nil]);
	if (!plist)
		return recognized ? DISK_INVALID : DISK_UNKNOWN;
	if ([plist isEqual: ImageTypeRaw]) // Better handled as a regular file
		return DISK_UNKNOWN;
	
	// TODO: support shadow files
	*attach_args = [NSArray arrayWithObject: path];
	
	// Check if it's shared
	int fd = open([lockfile UTF8String], O_EXLOCK | O_NONBLOCK | O_CLOEXEC);
	close(fd);
	*shared = (fd == -1);
	
	return DISK_VALID;
}

static NSString *dev_name(NSString *dev) {
	NSString *pref = [NSString stringWithUTF8String: _PATH_DEV];
	if (![dev hasPrefix: pref])
		return nil;
	return [dev substringFromIndex: [pref length]];
}

// Helper to get an IO Registry property
static NSNumber *get_val(io_service_t srv, const char *key, bool *ok) {
	CFTypeRef val = IORegistryEntryCreateCFProperty(srv,
		(CFStringRef)[NSString stringWithUTF8String: key], NULL, 0);
	if (val)
		return [(NSNumber*)val autorelease];
	
	*ok = false;
	return nil;
}
static bool image_info(NSString *dev, NSString **drive_id, bool *read_only,
		loff_t *size) {
	NSString *bsd = dev_name(dev);
	if (!bsd)
		return false;
	
	// Find the IORegistry item for our disk
	CFMutableDictionaryRef match = IOBSDNameMatching(kIOMasterPortDefault, 0,
		[bsd UTF8String]);
	if (!match)
		return false;
	io_service_t srv = IOServiceGetMatchingService(kIOMasterPortDefault, match);
	if (!srv)
		return false;
	
	// Get some properties
	bool ok = true;
	NSNumber *val;
	if ((val = get_val(srv, kIOMediaWritableKey, &ok)) && read_only)
		*read_only = ![val boolValue];
	if ((val = get_val(srv, kIOMediaSizeKey, &ok)) && size)
		*size = (loff_t)[val longLongValue];
	
	// Find the drive ID, by looking up in the hierarchy
	CFTypeRef drive = IORegistryEntrySearchCFProperty(srv, kIOServicePlane,
		DriveIdentifierKey, NULL,
		kIORegistryIterateRecursively | kIORegistryIterateParents);
	IOObjectRelease(srv);
	if (drive && drive_id)
		*drive_id = [(NSString*)drive autorelease];
	
	return ok && drive;
}

static void queue_for_cleanup(NSString *drive_id) {	
	// Start up the cleanup process
	if (cleanup_fd == -1) {
		int fds[2];
		if (pipe(fds) != 0)
			return;
		int rd = fds[0], wr = fds[1];
		
		pid_t pid = fork();
		if (pid == -1) {
			close(rd);
			close(wr);
			return;
		} else if (pid == 0) {	// child
			dup2(rd, STDIN_FILENO);
			execl("./cleanup", "./cleanup", NULL);
		}
		
		// Parent
		close(rd);
		cleanup_fd = wr;
	}
	
	const char *d = [drive_id UTF8String];
	write(cleanup_fd, d, strlen(d) + 1);
}

NSString *hdiutil_find_attached(NSString *drive_id) {
	// Create a matching dictionary to find this unique drive ID in the
	// IO Registry.
	NSDictionary *prop = [NSDictionary dictionaryWithObject: drive_id
		forKey: (NSString*)DriveIdentifierKey];
	NSDictionary *match = [[NSDictionary alloc] initWithObjectsAndKeys: prop,
		(NSString*)CFSTR(kIOPropertyMatchKey), nil];
	
	// See if the IO Registry entry exists
	io_service_t serv = IOServiceGetMatchingService(kIOMasterPortDefault,
		(CFDictionaryRef)match);
	if (!serv)
		return nil;
	
	// Find the related BSD name, so we can detach it
	NSString *dev = (NSString*)IORegistryEntrySearchCFProperty(serv,
		kIOServicePlane, CFSTR(kIOBSDNameKey), NULL,
		kIORegistryIterateRecursively);
	IOObjectRelease(serv);
	return dev;
}

// Actual disk_hdiutil factory
static disk_generic_status factory_real(const char *path, bool read_only,
		disk_generic **disk) {
	// See if we want this image
	NSString *image = [NSString stringWithUTF8String: path];
	bool shared = false;
	NSArray *args;
	disk_generic_status status = is_usable(image, &args, &shared);
	if (status != DISK_VALID)
		return status;
	
	// Attach ithe image
	NSString *dev = attach(args, read_only);
	NSString *drive_id;
	loff_t size;
	if (!image_info(dev, &drive_id, &read_only, &size)) {
		hdiutil_detach(dev);
		return DISK_INVALID;
	}
	
	// Open the disk
	int oflags = O_RDWR | O_EXLOCK;
	if (read_only)
		oflags = O_RDONLY | O_SHLOCK;
	int fd = open([dev fileSystemRepresentation], oflags | O_CLOEXEC);
	if (fd == -1) {
		hdiutil_detach(dev);
		return DISK_INVALID;
	}
	
	// Make sure we clean up after a crash
	if (!shared)
		queue_for_cleanup(drive_id);
	
	*disk = new disk_hdiutil(dev, fd, read_only, size, shared);
	return DISK_VALID;
}
// Just an autorelease wrapper around factory_real()
disk_generic_status disk_hdiutil_factory(const char *path, bool read_only,
		disk_generic **disk) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	disk_generic_status ret = factory_real(path, read_only, disk);
	[pool release];
	return ret;
}
