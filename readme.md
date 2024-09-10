# Zig Memstore

A basic redis clone using zig. Based on the [build-your-own book
for c/c++](https://build-your-own.org/redis).

## Installing and Running

- Download zig
- Clone repo
- `zig build`
- Server executable at `./zig-out/bin/zig-memstore.exe`
- Client executable at `./zig-out/bin/zig-memstore-client.exe`

## Debugging 

Using vscode + the CodeLLDB extension. On windows you also need the C/C++ extension too. Included in the repo are debugging launch configurations for the server and client.