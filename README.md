HDR Mode Enable/Disable for macOS
=================================

HDR toggle attempt via macOS private API with "safe" fallback.
Where "safe" in this context means "100% non-working."
The private API is the only thing that worked for simple toggle.

Necesitated because my MacBook Pro M4 has some goofy issue with Thunderbolt 5 hubs (OWC) and Thunderbolt 5 Cables (if it cost less than $50.00 believe me, I tried it) and multiple 4k monitors - even if one uses HDMI and another uses Thunderbolt 5.

Basically, whenever I turn on my LG OLED (which is technically a TV not a monitor) it sometimes starts in SDR mode rather than HDR mode.  Instead of clicking through _System Settings_ a bunch of times, I decided to write swift program to make it switch to HDR mode from the command line.

Issues
------

Use the `--display-id <number>` to select the monitor, using `--display <name>` never seems to work.

The `list` command always says "10-bit mode available: no". Do not believe it.

This was almost entirely written by *Cursor AI* because I haven't learned _swift_ yet and I don't know macOS private APIs and it was easier to ask Cursor, so I have no clue as to who actually owns this code. Um. It _was_ my idea.

Build Instructions
------------------

- clone the project
- `cd hdrctl`
- `make`

Execution
---------

```
% ./hdrctl on --display "LG TV SSCR2"
% ./hdrctl off --display "LG TV SSCR2"
% ./hdrctl toggle --display "LG TV SSCR2"
```
Oh, right I said not to do it that way.

```
% ./hdrctl list
....
DisplayID: 5  [main]
  Product names: <unknown>
  Vendor/Model/Serial(CG): 7789/33485/16843009
  Serial(IOKit): 0
  Current mode: 3840x2160 @ 120.00Hz, pixelEncoding=--------RRRRRRRRGGGGGGGGBBBBBBBB
  10-bit mode available: no

./hdrctl on -id 5
```
The above lists all monitors connected to the Mac.  I know my LG OLED runs at 120hz (yay LG OLED) in 4K, hence `-id 5`.

Works most of the time.
