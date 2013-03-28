*Downloads are now available here*: http://sourceforge.net/projects/b2gui/files/2011-11/

Building an Intel-Mac-friendly BasiliskII GUI

NOTE: This has only been tested on Mac OS X 10.6 Snow Leopard. For some reason, 10.7 builds are crashy, but if built on 10.6 it runs fine on future versions.

* Create a user `gtk`. As this user:
	* Build Gtk-OSX: https://live.gnome.org/GTK+/OSX/Building
		* Run the `gtk-osx-build-setup.sh` script
		* Use a `.jhbuildrc-custom` containing `setup_sdk(target="10.6", sdk_version="10.6", architectures=["i386"])`
		* Add jhbuild to the PATH
		* Then bootstrap, and build the package meta-gtk-osx-core
		* For Mac integration, we want gtk-mac-integration, which is included in the above.
		* We want a pretty theme--I find the gtk-quartz-engine to be rather unattractive. Build gtk-engines, for Clearlooks.
	* Install gtk-mac-bundler: https://live.gnome.org/GTK%2B/OSX/Bundling
		* It has a bug with new versions of pango, so use my branch "pango-modules": https://github.com/vasi/ige-mac-bundler/tree/pango-modules

* Build BasiliskIIGUI
	* Setup build environment by running `HOME=~gtk ~gtk/.local/bin/jhbuild shell`
	* Change directory to BasiliskII/src/Unix
	* Run autotools: `ACLOCAL_FLAGS="$ACLOCAL_FLAGS -I $PWD/m4" NO_CONFIGURE=1 ./autogen.sh`
	* Configure: `./configure --enable-standalone-gui --disable-fbdev-dga`. Verify that Gtk2 is detected
	* Build: `make BasiliskIIGUI`
	* Bundle it
		* Change dir to BasiliskII/src/MacOSX
		* Run `gtk-mac-bundler BasiliskIIGUI.bundle`
