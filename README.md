* Create a user `gtk`. As this user:
 	* Build Gtk-OSX: http://sourceforge.net/apps/trac/gtk-osx/wiki/Build
		* We need the package meta-gtk-osx-core
		* Also need ige-mac-integration at least version 0.9.8, previous versions don't like BasiliskIIGUI's menus. This is included in the above.
		* We want a pretty theme--I find the gtk-quartz-engine to be rather unattractive. Build gtk-engines, for Clearlooks.
		* Use a `.jhbuildrc.custom` containing `setup_sdk(target="10.4", sdk_version="10.4u", architectures=["i386"])`
	* Install ige-mac-bundler: http://sourceforge.net/apps/trac/gtk-osx/wiki/Bundle
		* It has a bug with paths containing spaces, so use my repo: https://github.com/vasi/ige-mac-bundler
		* Symlink it somewhere useful: `ln -sfn ~gtk/.local/bin/ige-mac-bundler ~gtk/gtk/inst/bin`

* Build BasiliskIIGUI
	* Setup build environment by running `HOME=~gtk ~gtk/.local/bin/jhbuild shell`
	* Change directory to src/Unix
	* Run autotools: `ACLOCAL_FLAGS="$ACLOCAL_FLAGS -I $PWD/m4" NO_CONFIGURE=1 ./autogen.sh`
	* Configure: `./configure --enable-standalone-gui`. Verify that Gtk2 is detected
	* Build: `make BasiliskIIGUI`
	* Bundle it
		* Change dir to src/MacOSX
		* Run `ige-mac-bundler BasiliskIIGUI.bundle`
