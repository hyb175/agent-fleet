{
  description = "agent-fleet — a tmux-native session manager for Claude Code agents";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));

      mkAgentFleet = pkgs:
        let
          # Everything the CLI, the tmux hooks, and the picker shell out to at
          # runtime. Put on the wrapper's PATH so the tmux server (booted by the
          # wrapped CLI) and its hook/popup children resolve them regardless of
          # the user's own PATH.
          runtimeDeps = with pkgs; [
            tmux fzf bashInteractive coreutils gnused gawk gnugrep findutils
            git zoxide ncurses
          ];
        in
        pkgs.stdenv.mkDerivation {
          pname = "agent-fleet";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ pkgs.makeWrapper ];
          # bash 5.x for patchShebangs — the sidenav needs bash 4+ (assoc arrays).
          buildInputs = [ pkgs.bash ];
          dontConfigure = true;
          dontBuild = true;

          installPhase = ''
            runHook preInstall

            mkdir -p "$out/bin" "$out/share/agent-fleet"
            cp -r bin conf scripts shims "$out/share/agent-fleet/"

            # Rewrite every '#!/usr/bin/env bash' to the Nix bash so panes/hooks
            # never fall back to macOS's bash 3.2.
            patchShebangs "$out/share/agent-fleet/bin" "$out/share/agent-fleet/scripts" "$out/share/agent-fleet/shims"

            # The real CLI resolves its root from its own path (readlink chain),
            # so a wrapper at $out/bin that execs the real script keeps
            # scripts/ and conf/ discoverable at $out/share/agent-fleet.
            makeWrapper "$out/share/agent-fleet/bin/agent-fleet" "$out/bin/agent-fleet" \
              --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps} \
              --set-default TMUX_BIN ${pkgs.tmux}/bin/tmux

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "tmux-native session manager for Claude Code agents";
            homepage = "https://github.com/hyb175/agent-fleet";
            license = licenses.mit;
            mainProgram = "agent-fleet";
            platforms = systems;
          };
        };
    in
    {
      packages = forAll (pkgs: rec {
        agent-fleet = mkAgentFleet pkgs;
        default = agent-fleet;
      });

      apps = nixpkgs.lib.genAttrs systems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/agent-fleet";
        };
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            tmux fzf bashInteractive coreutils gnused gawk gnugrep findutils
            git zoxide ncurses shellcheck
          ];
        };
      });

      formatter = forAll (pkgs: pkgs.nixpkgs-fmt);
    };
}
