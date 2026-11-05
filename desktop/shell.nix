# nix-shell desktop/shell.nix — build and run Fleet Desktop on Linux.
# rustup reads ./rust-toolchain.toml; GPUI links the rest.
{ pkgs ? import <nixpkgs> { } }:
let
  # Loaded with dlopen at runtime, so they must be on the library path too.
  runtime = with pkgs; [ vulkan-loader wayland libxkbcommon xorg.libX11 xorg.libxcb xorg.libXcursor xorg.libXi xorg.libXrandr fontconfig freetype ];
in
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [ rustup pkg-config cmake ];
  buildInputs = runtime ++ (with pkgs; [ openssl zstd ]);
  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtime;
}
