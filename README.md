# SafariPicker

Extra link menu options and upload-any-file for Safari, based on parts of [SafariPlus](https://github.com/opa334/SafariPlus).

<img width="1179" height="1179" alt="Picroll_20261011_174355" src="https://github.com/user-attachments/assets/430d85bb-0282-4fde-b951-8e9b65065266" />

## Features

- **New Tab + Background**: "Open in New Tab" and "Open in Background" side by side in the link menu.
- **Private / Normal Mode**: open a long-pressed link in the other browsing mode.
- **Upload Any File**: "Local Files" in the upload menu opens a read-only file browser with favorites, Go to Path, Copy Path, search, sorting and grouping by kind.

## File access

- The picker can only read, never write. By default it reaches `/var/mobile` and the Jailbreak root. 
- The **Allow System File Access** setting (off by default) extends this to the whole file system. Thanks libSandy!

## Build

Needs [roothide Theos](https://github.com/roothide/theos)

```bash
make package FINALPACKAGE=1 SCHEME=rootless   #rootless
make package FINALPACKAGE=1 SCHEME=roothide   #roothide
```

Add `DIAGNOSTICS=1` for a debug build that logs to `oslog | grep SafariPicker`.

## License

GPLv3, see [LICENSE.md](LICENSE.md). Parts based on SafariPlus and the libSandy header are MIT licensed by Lars Fröder (opa334).
