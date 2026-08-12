# Patches

## `sdl2-for-pascal-circlesdl2.patch`

Applies to the **SDL2-for-Pascal** binding — the Pascal translation of SDL2's
headers that Pascal SDL programs carry. The copy this was cut against is the
one vendored in Fairtris (`source/sdl/`), and the same hunk applies to every
generation of that binding, because the block it edits has not changed since
the project was called Pascal-SDL-2-Headers.

Apply it to a copy of the binding and point `SDL2_PASCAL_UNITS` at the result:

```sh
patch -p1 -d <binding-dir> < patches/sdl2-for-pascal-circlesdl2.patch
```

### What it does, and why it is needed

The binding writes every declaration as `external SDL_LibName`, and declares
`SDL_LibName` in three arms: Windows, Unix, and Classic Mac OS. A target that
matches none of them leaves the constant undeclared, and the compile stops on
the first declaration that uses it — with `identifier not found`, naming
neither the constant's purpose nor the platform. The patch adds a fourth arm
for `circlesdl2`.

The name it declares is never opened and never looked up. There is no loader
on this machine: every SDL2 entry point is resolved when the host kernel's own
Circle build links `libSDL2-<board>.a`, exactly as a C caller's is. The
constant exists only so that the `external` clauses have something to name.

### Why the other arms cannot be used instead

Each was tried against the compiler rather than reasoned about.

- **`-dUNIX`** makes the binding's interface use the units `X`, `XLib` and
  `UnixType`, and `-dWINDOWS` makes it use `Windows`. None of those exists on
  this target, and writing stand-ins for them would be a far larger change
  than this one — and a lie that reaches the record layouts in `sdlsyswm.inc`.

- **`-dMACOS`** compiles, and produces an image that can never link. The
  binding's `jedi.inc` puts Free Pascal into Delphi mode (`{$MODE DELPHI}`),
  which defines the symbol `DELPHI`; every declaration then reads

  ```pascal
  external SDL_LibName {$IFDEF DELPHI} {$IFDEF MACOS} name '_SDL_Init' {$ENDIF} {$ENDIF};
  ```

  so with `MACOS` also defined, every entry point is renamed with a leading
  underscore. `SDL_Init` becomes `_SDL_Init`, which nothing defines. This is
  worth knowing because the failure arrives at the link, a long way from the
  flag that caused it, and it looks like a library with no SDL in it.

### What it deliberately does not do

It removes nothing and stubs nothing. The binding still declares the whole of
SDL2, and the entry points this library does not implement stay declared —
Free Pascal emits a reference only where a call is written, so a declaration
nobody calls costs nothing and never reaches the linker. That is the same
behaviour a C consumer gets from a header, and it is what lets an application
be ported by relinking it.
