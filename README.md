*Downloads are now available here*: http://sourceforge.net/projects/b2gui/files/2011-11/

Building an Intel-Mac-friendly BasiliskII GUI.

* Create a user `gtk`. As this user:
 	* Build Gtk-OSX: http://sourceforge.net/apps/trac/gtk-osx/wiki/Build
		* We need the package meta-gtk-osx-core
		* Also need ige-mac-integration at least version 0.9.8, previous versions don't like BasiliskIIGUI's menus. This is included in the above.
		* We want a pretty theme--I find the gtk-quartz-engine to be rather unattractive. Build gtk-engines, for Clearlooks.
		* Use a `.jhbuildrc.custom` containing `setup_sdk(target="10.4", sdk_version="10.4u", architectures=["i386"])`
		  Or on Lion, `setup_sdk(target="10.6", sdk_version="10.6", architectures=["i386"])`,
		* Lion also requires adding `skip.append("libiconv")` to the `.jhbuild.custom`
	* Install ige-mac-bundler: http://sourceforge.net/apps/trac/gtk-osx/wiki/Bundle
		* It has a bug with paths containing spaces, so use branch "patch-1" of my repo: https://github.com/vasi/ige-mac-bundler
		* Symlink it somewhere useful: `ln -sfn ~gtk/.local/bin/ige-mac-bundler ~gtk/gtk/inst/bin`

* Build BasiliskIIGUI
	* Setup build environment by running `HOME=~gtk ~gtk/.local/bin/jhbuild shell`
	* Change directory to src/Unix
	* Run autotools: `ACLOCAL_FLAGS="$ACLOCAL_FLAGS -I $PWD/m4" NO_CONFIGURE=1 ./autogen.sh`
	* Configure: `./configure --enable-standalone-gui --disable-fbdev-dga`. Verify that Gtk2 is detected
	* Build: `make BasiliskIIGUI`
	* Bundle it
		* Change dir to src/MacOSX
		* Run `ige-mac-bundler BasiliskIIGUI.bundle`

* FIXME!
	* GTK-OSX build docs are now here: https://live.gnome.org/GTK+/OSX/Building
	* Recent XCode has only 10.7 SDK
	* ige-mac-integration is now included in meta-gtk-osx-core
	* ige-mac-bundler is now gtk-mac-bundler, doesn't need patch
	* Build results in random crashes :(
