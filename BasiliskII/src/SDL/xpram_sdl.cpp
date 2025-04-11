/*
 *  xpram_sdl.cpp - XPRAM handling, SDL implementation
 *
 *  Basilisk II (C) 1997-2008 Christian Bauer
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

#include "sysdeps.h"

#include <stdio.h>
#include <stdlib.h>
#include "my_sdl.h"
#include "prefs.h"
#include "xpram.h"


// XPRAM file name and path
const char XPRAM_FILE_NAME[] = ".basilisk_ii_xpram";

static const char *getPath() {
	const char *path = PrefsFindString("xpram");
	if (path && *path) return path;
	// Build a full-path to the file
	static char full_path[4096];
	const char *dir = SDL_getenv("HOME");
	if (!dir)
		dir = "./";
	SDL_snprintf(full_path, sizeof(full_path), "%s/%s", dir, XPRAM_FILE_NAME);
	return full_path;
}

/*
 *  Load XPRAM from settings file
 */

void LoadXPRAM(const char *dir)
{
	FILE *f = fopen(getPath(), "rb");
	if (f != NULL) {
		fread(XPRAM, 256, 1, f);
		fclose(f);
	}
}


/*
 *  Save XPRAM to settings file
 */

void SaveXPRAM(void)
{
	FILE *f = fopen(getPath(), "wb");
	if (f != NULL) {
		fwrite(XPRAM, 256, 1, f);
		fclose(f);
	}
}


/*
 *  Delete PRAM file
 */

void ZapPRAM(void)
{
	remove(getPath());
}
