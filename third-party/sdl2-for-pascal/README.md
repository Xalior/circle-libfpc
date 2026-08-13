# SDL2-for-Pascal (vendored)

This directory is a vendored copy of the Pascal SDL2 binding. It was not
written in this repository — every file in it, `sdl2.pas`, `sdl2_gfx.pas`,
`sdl2_image.pas`, `sdl2_mixer.pas`, `sdl2_net.pas`, `sdl2_ttf.pas`, `jedi.inc`
and the rest of the `.inc` files, is third-party source, carried here so that
a Pascal program using SDL has somewhere in this repository to find it.

## Where this copy came from

The binding is [SDL2-for-Pascal](https://github.com/PascalGameDevelopment/SDL2-for-Pascal),
formerly Pascal-SDL-2-Headers — a Pascal translation of SDL2's C headers, so
that a Pascal program can call SDL2 the way a C program does. Every file
carries this header:

```
Simple DirectMedia Layer
Copyright (C) 1997-2013 Sam Lantinga <slouken@libsdl.org>

Pascal-Header-Conversion
Copyright (C) 2012-2020 Tim Blume aka End/EV1313

SDL2-for-Pascal
Copyright (C) 2020-2021 PGD Community
```

This particular copy was not cut directly from that project's own repository.
It was cut from the copy that [furious-programming/fairtris](https://github.com/furious-programming/fairtris)
carries at `source/sdl/` — a Pascal SDL2 game that vendors the binding the
same way this directory does, and one of the ports this build was proved
against. It is an older revision of the binding than the upstream project's
current `HEAD`: fairtris's copy predates files such as `sdlatomic.inc`,
`sdlerror_c.inc`, `sdlguid.inc` and `sdlhidapi.inc` that later revisions carry,
and this directory matches fairtris's copy file-for-file except for the one
patched line described below.

## Licence

SDL2-for-Pascal is dual-licensed; either licence may be used. Both are
carried here exactly as the upstream project ships them:

- `MPL-LICENSE` — the Mozilla Public License, Version 2.0.
- `zlib-LICENSE` — the zlib license.

## The one patch already applied

`sdl2.pas` in this directory is not a clean copy: it already carries
`../../patches/sdl2-for-pascal-circlesdl2.patch`, which adds a fourth arm —
`CIRCLESDL2` — to the platform block that declares the library name every
`external` declaration in the binding names. Read
`../../patches/README.md` for what the patch does and why it is needed; every
Pascal SDL program needs it; it is not specific to any one port.

Regenerating this directory from a fresh upstream (or fairtris) checkout
means reapplying that patch — nothing else in this copy has been changed by
hand.
