Third-party origins in TequilaDash (as of 2026-08-17)

This project is published under GNU Affero General Public License v3.0
because tunnel/applist code is adapted from StikDebug (AGPL-3.0). See LICENSE.

1. TequilaDash/Engine/bad_query.c, bad_query.h, xpc_shim.h
   Adapted from forcequitOS/bad_query (public GitHub push 2026-08-11).
   Upstream had no LICENSE file at the time of adaptation.
   TequilaDash redistributes these files with that attribution. The upstream author
   did not grant a public license; a later rewrite remains desirable.

2. TequilaDash/Tunnel/applist.m, applist.h, and RPPairing usage in TunnelContext.m
   Adapted from StikDebug / StikJIT idevice bindings.
   StikDebug is licensed under GNU AGPL-3.0.
   That is why TequilaDash as a combined work is AGPL-3.0.

3. TequilaDash/Tunnel/libidevice_ffi.a and idevice.h
   Built from jkcoxson/idevice, MIT License.
   https://github.com/jkcoxson/idevice

4. vendor/SWCompression (4.8.6) and vendor/BitByteData (2.0.4)
   Timofey Solomko, MIT License.
   Used to extract 7z, tar, gzip, bzip2, xz, lz4, lzma, and zip (non-password).
   TequilaDash decrypts 7-Zip AES-256 archives (SHA-256 key derivation + AES-CBC)
   itself; SWCompression only parses those folders.
   https://github.com/tsolomko/SWCompression
   https://github.com/tsolomko/BitByteData

5. TequilaDash/Engine/CrashReport/ (19 Swift files)
   Adapted from Xrash (github.com/owngoal-dev/Xrash), MIT License, OwnGoal Studio.
   Copied verbatim from Packages/XrashKit/Sources/XrashReport at upstream main
   commit 8d00f4c48a (2026-10-15); parsing logic unchanged.
   Local edits are limited to Swift 6 strict-concurrency annotations
   (nonisolated(unsafe)) required to compile under -strict-concurrency=complete.
   License text: Resources/Licenses/xrash.txt.
   https://github.com/owngoal-dev/Xrash

6. TequilaDash/Services/MachOLoader/uloader.c, uloader.h
   Ported from Nyxian's ProcEnvironment/Surface/kxld (emexlab),
   GNU AGPL-3.0-or-later. This is the user-space Mach-O dylib loader
   that bypasses dyld library validation for ad-hoc signed modules.
   https://github.com/emexlab/Nyxian

7. vendor/litehook/src (litehook.c, litehook.h), vendor/litehook/external/include
   Adapted from LiveContainer/litehook (github.com/LiveContainer/litehook),
   MIT License, Copyright (c) 2022-2024 Lars Fröder.
   Used as the hooking substrate for in-container app launching and JITLess:
   dyld_shared_cache symbol lookup, GOT rebinding, and function branch rewriting.
   Copied verbatim; local edits are none.
   License text: Resources/Licenses/litehook.txt.

8. vendor/fishhook (fishhook.c, fishhook.h)
   Adapted from facebook/fishhook (github.com/facebook/fishhook),
   BSD 3-Clause License, Copyright (c) 2013, Facebook, Inc.
   Used to rebind imported symbols at load time; same role it has in LiveContainer.
   Copied verbatim; local edits are none.
   License text: Resources/Licenses/fishhook.txt.

9. vendor/roothide (roothide path layer, Tier B-3)
   Vendored from roothide/libroothide (github.com/roothide/libroothide) at main
   commit cb236f9, MIT License, Copyright (c) 2023 RootHide.
   Used as the jbroot path-algebra core and the symredirect engine for the
   per-guest rootfs (Documents/rootfs/.jbroot-<rand>): path mapping, random
   root naming, and offline Mach-O symbol rebinding to the vroot shim library.
   Local edits (documented in vendor/roothide/README.md): the hardcoded
   /var/containers/Bundle/Application assumption is removed, __roothideinit_JBROOT
   is set externally (TD_VROOT/TD_VROOT_MODE, same gate as Tier A), and the
   symredirect CLI main() became a callable library function. TDRootHideInit.{h,c}
   in that directory is our own code, not upstream.
   License text: Resources/Licenses/roothide.txt.
   https://github.com/roothide/libroothide
