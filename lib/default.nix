# lib/default.nix — profile assembly for dsh-nix-wrapper.
#
# buildProfile turns a core + a plugin list (each deriving to
# out/lib/node_modules/<name>) into a complete dsh profile directory: a flat
# node_modules (symlinkJoin, first-wins) + a package.json carrying the cordis
# bundles and the pi2dsh dependency map. Pure function of { lib, pkgs } — no
# references to core/profile/home — reusable by any consumer flake.
{ lib, pkgs }:
let
  buildProfile =
    { core, plugins
    , bundles ? [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" ]
    , piDependencies ? { }
    }:
    let
      coreNm = "${core}/lib/node_modules/@deepseek-ai/dsh/node_modules";
      pluginNms = map (p: "${p}/lib/node_modules") plugins;
      nm = pkgs.symlinkJoin {
        name = "dsh-profile-node_modules";
        paths = pluginNms ++ [ coreNm ];
      };
      bundlesJson = builtins.toJSON bundles;
      depsJson = builtins.toJSON piDependencies;
    in
    pkgs.runCommand "dsh-profile" { } ''
      mkdir -p $out
      ln -s ${nm} $out/node_modules
      cat > $out/package.json <<EOF
      {
        "name": "dsh-profile-nix",
        "private": true,
        "dependencies": ${depsJson},
        "dsh": {
          "profile": {
            "bundles": ${bundlesJson}
          }
        }
      }
      EOF
    '';
in
{
  inherit buildProfile;
}
