# Third-party notices and corresponding source

Project author: **wuldas**. Original project code and scripts are distributed under **GPL-3.0-only**; see `LICENSE`. Third-party files and linked components retain their own copyright and license terms. No warranty is provided.

Repository and source: https://github.com/wuldas/wsa-houdini-scudo-fix

Release and equivalent source downloads: https://github.com/wuldas/wsa-houdini-scudo-fix/releases/tag/v0.4.0-experimental

## Magisk module installer

`module/META-INF/com/google/android/update-binary` is an unmodified copy of Magisk 30.6 `scripts/module_installer.sh`, copyright its upstream authors, distributed under GNU GPL version 3. Changing the module's author field does not change attribution for this upstream file.

- Project: https://github.com/topjohnwu/Magisk
- Source: https://github.com/topjohnwu/Magisk/blob/v30.6/scripts/module_installer.sh
- License: https://github.com/topjohnwu/Magisk/blob/v30.6/LICENSE
- File SHA256: `bcf4b1d9913f3af17755569c853e0b5a75b8005f6a18eb3f86dadcc0e968c29d`

The installer source is included verbatim in this repository and in the module ZIP. Magisk itself is not bundled.

## GNU C Library (glibc)

The prebuilt daemon is statically linked with **glibc 2.36**, Debian package version **2.36-9+deb12u14**. glibc is primarily LGPL-2.1-or-later, with additional component notices. See `licenses/LGPL-2.1.txt` and the unmodified Debian package notice `licenses/glibc-COPYRIGHT.txt`. The historical version wording inside that notice is retained verbatim; build package identity is given here.

The same GitHub Release offers the complete corresponding Debian glibc source, including Debian changes, free of charge:

| Release asset | SHA256 |
|---|---|
| `glibc_2.36.orig.tar.xz` | `a543c02070d46ccaf866957efd13f10c924daa74c86a90a0254db09a92a708ee` |
| `glibc_2.36-9+deb12u14.debian.tar.xz` | `cf4ac9cd98185452cae3ef34e2e4ee12753e3d93fd0c62c61396d4a47eec902f` |
| `glibc_2.36-9+deb12u14.dsc` | `cfe1f0b8dc1fa211ce5a45b3725cc38b29f88667f1140ebdca6de35cf9c6f1fd` |

Original source location: https://deb.debian.org/debian/pool/main/g/glibc/

Download all three files into one directory, then use Debian's `dpkg-source -x glibc_2.36-9+deb12u14.dsc` to obtain the complete patched source. Its `debian/` directory contains the packaging/build instructions. No glibc source changes were made for this project.

The daemon's complete source is `wsa-vfork-guard.c`; `Build-Guard.sh` produces both a relinkable object and the static executable. The Release also includes `wsa-vfork-guard.o`. Users may modify the library or this project and rebuild/relink. For a compatible replacement libc toolchain, the linking step is:

```sh
cc -static -fno-pie -no-pie -o wsa-vfork-guard wsa-vfork-guard.o
```

Select the replacement libc's headers/startup objects/library paths through the replacement compiler/toolchain as appropriate. Rebuild the source if changing ABI definitions. The object/source files are not flashable Magisk modules.

## GCC runtime and toolchain

The verified executable was built with **GCC 12.2.0**, Debian **12.2.0-14+deb12u1**, using unmodified system libraries. GCC runtime components are covered by GPLv3 with the GCC Runtime Library Exception 3.1 where applicable. The full Debian copyright and runtime-exception notices are preserved in `licenses/GCC-COPYRIGHT.txt`.

- GCC Runtime Library Exception: https://www.gnu.org/licenses/gcc-exception-3.1.html
- Compiler source distribution: https://deb.debian.org/debian/pool/main/g/gcc-12/

## Not distributed

This repository and its Releases do not distribute app APKs, Intel Houdini, WSA images, Android system libraries, personal information, device backups, screenshots or runtime logs. Users must supply their own compatible installation and comply with its applicable licenses. This is an independent compatibility experiment, not an official Microsoft, Intel, Google, Magisk or app-vendor release.
