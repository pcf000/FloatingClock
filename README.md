# FloatingClock
A Mac app that mimics the old SimpleFloatingClock app

SimpleFloatingClock.app is an application from Greg Weston in 2007
and 2008.  (The copyright is 2007-2012, but the latest modified file is
from 2008.)  To quote its README:

    It's a clock. A simple, floating analog clock that sits on your desktop any where you'd like to put it. It works on Mac OS X 10.4 and up, and runs natively on PPC and Intel machines.

    Because Apple got rid of that option in the stock clock with the release of Leopard (Mac OS X 10.5) on October 26, 2007. Some people like it.

I don't know where Greg Weston has gotten to, and the source is not
available, and the binaries that we have are only for PPE and x86, and
Apple is about to shut down Rosetta for ARM.  So here's a rewrite, using
Claude and iteration, to reproduce as much of the functionality as I
can.

It does the things I care about almost exactly the same.  It does other
things similarly but not necessarily exactly.  It lacks
internationalisation, and it lacks the ability to have multiple clocks
within the single app.  It doesn't have a decent icon.

Some of the display is a little different, and the settings menus are
considerably different, but that's because I let the glorified
auto-complete write the code for me.  I don't fiddle with settings much,
once I like them, so I don't care much if the menus are different.
Sorry.

Build by running build.sh to make a FloatingClock.app bundle, and move
the bundle under /Applications or /Applications/Utilities.
