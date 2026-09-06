# dsh-nix-wrapper — reusable dsh profile module + thin dsh wrapper builder.
#
#   modules.default   the reusable dsh profile module ("wrapper module"): a
#                     consumer imports it into the nixpkgs module system and
#                     sets options (core, plugins, bundles, piDependencies,
#                     devMounts). The nvim-inogai / nix-wrapper-modules analog.
#   lib.<sys>         buildProfile (flat node_modules + package.json assembler),
#                     evalProfileModule (option-eval helper), mkDsh (thin `dsh`
#                     wrapper builder: daemon env + idempotent DSH_HOME
#                     provision + symlink forest).
#
# Core + plugins come from the sibling repo `dsh-nix-packages`
# (github:an4nsi/dsh-nix-packages); consumers wire both as flake inputs.
{
  description = "dsh-nix-wrapper: reusable dsh profile module + mkDsh builder";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;
      dshModule = import ./module.nix;
      # Throwaway consumer (fake core + fake plugins) that builds the REAL mkDsh
      # wrapper, so tests/provision-node_modules.bash can exercise the provision
      # logic end-to-end — migration, idempotency, conflicts — without
      # dsh-nix-packages or a real dsh core. Dev-mount srcs point at absent /tmp
      # paths on purpose: dangling links are exactly what provisioning must
      # tolerate, and dev-mode config sources only WARN when missing.
      smokeWrapper = system:
        let
          pkgs = import nixpkgs { inherit system; };
          lib = nixpkgs.lib;
          fakeCore = pkgs.runCommand "dsh-smoke-core" { } ''
            mkdir -p "$out/bin" "$out/lib/node_modules/@deepseek-ai/dsh/node_modules/@fake"
            printf '#!/bin/sh\n' > "$out/bin/dsh"
            echo 'echo "dsh-smoke: fake dsh launched"' >> "$out/bin/dsh"
            chmod +x "$out/bin/dsh"
            for p in core-dep @fake/dep; do
              mkdir -p "$out/lib/node_modules/@deepseek-ai/dsh/node_modules/$p"
              printf '{"name":"smoke","version":"0.0.0"}\n' > "$out/lib/node_modules/@deepseek-ai/dsh/node_modules/$p/package.json"
            done
          '';
          fakePlugin = path: kind: pkgs.runCommand "dsh-smoke-plugin-${kind}" { } ''
            mkdir -p "$out/lib/node_modules/${path}"
            printf '{"name":"smoke","version":"0.0.0"}\n' > "$out/lib/node_modules/${path}/package.json"
          '';
          pluginKind = path: lib.replaceStrings [ "/" "@" ] [ "-of-" "scope-" ] path;
        in
        (import ./lib/mk-dsh.nix {
          inherit pkgs lib;
          evalProfileModule = self.lib.${system}.evalProfileModule;
        }) {
          core = fakeCore;
          plugins = map (p: fakePlugin p (pluginKind p))
            [ "dsh-fake-bare" "dsh-fake-extra" "@fake/scope-pkg" ];
          bundles = { web = [ "@deepseek-ai/dsh" ]; headless = [ "@deepseek-ai/dsh" ]; };
          devMounts = {
            "dsh-fake-bare".src = "/tmp/dsh-smoke-src-bare";
            "dsh-fake-extra".src = "/tmp/dsh-smoke-src-extra";
            "@fake/scope-pkg".src = "/tmp/dsh-smoke-src-scoped";
          };
          homeConfig = "/tmp/dsh-smoke-config";   # dev mode: missing sources only WARN
        };
    in
    {
      # The reusable dsh profile module. Reading `buildProfile = import ./lib`
      # with a consumer's pkgs is done via evalProfileModule below.
      modules = {
        default = ./module.nix;
      };

      lib = forAllSystems (system:
        let
          lib = nixpkgs.lib;
          pkgs = import nixpkgs { inherit system; };
          # Evaluate ./module.nix against a given profile recipe + dev mounts.
          #   dsh-nix-wrapper.lib.${system}.evalProfileModule {
          #     inherit pkgs core plugins bundles piDependencies;
          #     devMounts = { "dsh-fork-view" = { src = "/abs/path"; }; };
          #   }
          # returns { profile, devProfile, config } — `profile` is the
          # store-pinned buildProfile result (identical when devMounts = {});
          # `devProfile` folds the dev overlay in first so each devMounted
          # node_modules entry points at its editable src.
          evalProfileModule =
            { core, plugins
            , bundles ? [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" ]
            , piDependencies ? { }
            , devMounts ? { }
            , patchReload ? null
            , profilePkgs ? pkgs
            , profileBuild ? (import ./lib { lib = nixpkgs.lib; pkgs = profilePkgs; }).buildProfile
            }:
            let
              consumer = { config, ... }: {
                config.core = core;
                config.plugins = plugins;
                config.bundles = bundles;
                config.piDependencies = piDependencies;
                config.devMounts = devMounts;
                config.patchReload = patchReload;
              };
              ev = lib.evalModules {
                modules = [ consumer dshModule ];
                specialArgs = {
                  pkgs = profilePkgs;
                  buildProfile = profileBuild;
                };
              };
            in
            {
              inherit (ev.config) config;
              profile = ev.config.build.profile;
              devProfile = ev.config.build.devProfile;
            };
        in
        {
          inherit evalProfileModule;
          # flat node_modules + package.json profile assembler (pure {lib,pkgs})
          buildProfile = (import ./lib { inherit lib pkgs; }).buildProfile;
          # Phase 1 thin dsh wrapper builder — see lib/mk-dsh.nix.
          mkDsh = import ./lib/mk-dsh.nix { inherit pkgs lib evalProfileModule; };
        });

      # Throwaway consumer (fake core + plugins) building the REAL mkDsh wrapper,
      # for tests/provision-node_modules.bash — see smokeWrapper in the let.
      packages = forAllSystems (system: {
        dsh-smoke = (smokeWrapper system).packages.dsh;
        dsh-smoke-unlink = (smokeWrapper system).packages.dsh-unlink;
      });
      checks = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; }; in {
          wrapper-smoke = pkgs.runCommand "dsh-wrapper-smoke" { } ''
            ${pkgs.bash}/bin/bash ${./tests/provision-node_modules.bash} ${(smokeWrapper system).packages.dsh}/bin ${(smokeWrapper system).packages.dsh-unlink}/bin > "$out" 2>&1
          '';
        });
    };
}
