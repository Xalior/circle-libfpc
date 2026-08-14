{
  m0.pas — the smallest Pascal program that proves it ran.

  It allocates nothing, opens nothing and prints nothing, because none of
  those work yet: this target has no memory manager, no thread manager and no
  file or console layer installed, and each of those is a later milestone.

  What it does is call one C function, and the host kernel logs from there.
  The Pascal program itself performs no I/O — it may not, because a device
  belongs to a core this program does not run on, and Pascal's own console
  layer does not exist. The C function is the wrapper seam this library is
  built out of, and it is the host kernel's own code on the far side of it.
}
program m0;

{ Defined by the host kernel, in C++. The Pascal side declares it and calls
  it; everything about reaching the serial console happens beyond this call
  and belongs to the kernel. }
procedure m0_entry_reached; cdecl; external name 'm0_entry_reached';

begin
  m0_entry_reached;
end.
