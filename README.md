# remote-edit-ni for atom.io

[![Build Status](https://travis-ci.org/newinnovations/remote-edit-ni.svg?branch=master)](https://travis-ci.org/newinnovations/remote-edit-ni)

Remote-edit-ni is a continuation of the abandoned remote-edit package. It is compatible with the latest version of atom (1.41.x at the time of writing) and contains a lot of new features.

This version integrates the work of Andreas Bontozoglou (@urban-1) and Martin van der Werff (@newinnovations).

## Getting started

Use <kbd>Alt+r b</kbd> (or <kbd>&#8984;+r b</kbd> for Mac) to browse the list of configured hosts. Which will be empty at first.

In this view press <kbd>shift+s</kbd> to add your SFTP/SSH host or use <kbd>shift+f</kbd> to add your FTP host.

Then press <kbd>Alt+r b</kbd> / <kbd>&#8984;+r b</kbd> again and select your host. Remote edit will connect to your host and show the list of remote files in a side window (pane). Navigation should be pretty straightforward. Double click to open files or directories or use your keyboard.

## Please note / caveats

There is currently no check to see whether the file was changed on the remote host. Saving will overwrite any changes on the remote server.

All information is stored in cleartext on disk. This includes passwords and passphrases. Please use only your ssh-agent for authentication so no sensitive information needs to be stored by remote-edit.


## Main keyboard shortcuts

- <kbd>Alt+r b</kbd> / <kbd>&#8984;+r b</kbd> -
Select remote host and start browsing in configured directory (or last directory when selected in preferences).

- <kbd>Alt+r m</kbd> / <kbd>&#8984;+r m</kbd> -
Browse remote host in directory of the current editor tab.

- <kbd>Alt+r v</kbd> / <kbd>&#8984;+r v</kbd> -
Show/hide remote-edit panel

- <kbd>Alt+r o</kbd> / <kbd>&#8984;+r o</kbd> -
Show open (downloaded) remote files.

- <kbd>Alt+r f</kbd> / <kbd>&#8984;+r f</kbd> -
Give focus to the remote-edit file browser. This allows you to navigate with
keyboard (up/down/enter/backspace/escape)

- <kbd>Alt+r l</kbd> / <kbd>&#8984;+r l</kbd> -
Give focus to the remote-edit file browser's filter bar which can also be used
for navigation to a different folder

- <kbd>Alt+r d</kbd> / <kbd>&#8984;+r d</kbd> -
Disconnect all open server connections. Server connections are normally kept open to improve save and browse performance.


### shortcuts within _host selection_ dialog

- <kbd>Shift+a</kbd> or <kbd>Shift+s</kbd> -
Add sftp host.

- <kbd>Shift+f</kbd> -
Add ftp host.

- <kbd>Shift+e</kbd> -
Edit hosts.

- <kbd>Shift+d</kbd> -
Delete hosts or downloaded files. Usable when selecting hosts (_Browse_) or open files (_Show open remote files_).


## TODO

* Consider another location for the temporary files
* Enumerate the open file list when atom is launched

## Credits
This is a fork of a project created by Sverre Aleksandersen (@sveale). It was
forked to implement bug fixes and several new features.
