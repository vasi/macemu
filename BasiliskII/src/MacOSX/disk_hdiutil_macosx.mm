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

#include <paths.h> // for _PATH_DEV

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/storage/IOMedia.h>


// TODO
// - Restore sparsebundle driver
// - Test read-only
// - Test locking
// - Test crashing
// - Shadow disks


// Unique ID of an attached image
static const CFStringRef DriveIdentifierKey =
	 CFSTR("hdiagent-drive-identifier");

// Raw disk image
static const NSString *ImageTypeRaw = @"RAW*";


// Run hdiutil and return the plist output, or NULL on failure.
static id hdiutil(NSArray *args);

// Attach a disk image, returning the full dev path, or NULL on failure.
static NSString *attach(NSArray *image_args, bool read_only);

// Detach a disk image
static void detach(NSString *dev);

// Do we want this image? If so, return appropriate arguments for attach(), 
// otherwise, return NULL.
static NSArray *is_usable(NSString *path);

// Get information about a mounted image, return true on success.
static bool image_info(NSString *dev, NSString **drive_id, bool *read_only,
	loff_t *size);

// Get just the device name (BSD name) part of a device path: /dev/foo => foo
static NSString *dev_name(NSString *dev);


struct disk_hdiutil : disk_generic {
	disk_hdiutil(NSString *dev, int fd, bool read_only, loff_t size)
	: dev([dev retain]), fd(fd), read_only(read_only), total_size(size) { }
	
	virtual ~disk_hdiutil() {
		close(fd);
		detach(dev);
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
	loff_t total_size;
};


static id hdiutil(NSArray *args) {
	// Setup the hdiutil process
	NSTask *task = [[[NSTask alloc] init] autorelease];
	[task setLaunchPath: @"/usr/bin/hdiutil"];
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

static void detach(NSString *dev) {
	hdiutil([NSArray arrayWithObjects: @"detach", dev, nil]);
}

static NSArray *is_usable(NSString *path) {
	// This checks both the format, and whether the disk is locked or in-use
	id plist = hdiutil([NSArray arrayWithObjects:
		@"imageinfo", @"-format", @"-plist", path, nil]);
	if (!plist)
		return nil;
	if ([plist isEqual: ImageTypeRaw]) // Better handled as a regular file
		return nil;
	
	// TODO: support shadow files
	
	return [NSArray arrayWithObject: path];
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


// Actual disk_hdiutil factory
static disk_generic *factory_real(const char *path, bool read_only) {
	NSString *image = [NSString stringWithUTF8String: path];
	NSArray *args = is_usable(image);
	if (!args)
		return NULL;
	
	NSString *dev = attach(args, read_only);
	NSString *drive_id;
	loff_t size;
	if (!image_info(dev, &drive_id, &read_only, &size)) {
		detach(dev);
		return NULL;
	}
	
	int oflags = O_RDWR | O_EXLOCK;
	if (read_only)
		oflags = O_RDONLY | O_SHLOCK;
	int fd = open([dev fileSystemRepresentation], oflags);
	if (fd == -1) {
		detach(dev);
		return NULL;
	}
	
	// TODO: queue for cleanup
	
	return new disk_hdiutil(dev, fd, read_only, size);
}
// Just an autorelease wrapper around factory_real()
disk_generic *disk_hdiutil_factory(const char *path, bool read_only) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	disk_generic *ret = factory_real(path, read_only);	
	[pool release];
	return ret;
}
