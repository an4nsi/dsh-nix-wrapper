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
    };
}
