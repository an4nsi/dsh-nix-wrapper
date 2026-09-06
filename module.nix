# module.nix — a reusable dsh profile module (the dsh-nix-wrapper module).
#
# Mirrors the nvim-inogai / nix-wrapper-modules approach: a consumer imports
# this module into the nixpkgs module system and sets options, rather than
# hand-assembling a profile in an app flake. The module owns:
#
#   * the plugin + bundle + piDependencies selection (config.plugins, ...)
#   * the dev-mount surface — options.devMounts points any plugin at an
#     editable, OUT-OF-STORE source path so its files hot-reload with no
#     nix rebuild (the same "impure string path for testing" idea nvim uses).
#
# The module is pure in nix terms: it never bakes a dev src into a store
# derivation. It produces BOTH:
#   * a fully store-pinned profile (buildProfile, identical to today when
#     devMounts = {}), and
#   * a dev overlay derivation whose out/lib/node_modules/<name> entries are
#     leaf symlinks to each devMount's editable src. Folding it into the
#     profile via buildProfile's symlinkJoin *first* gives first-wins: the
#     dev-mounted node_modules entry points at src and hot-reloads.
#
# Mount granularity = the NODE_MODULES ENTRY, not a file inside the plugin.
# Each dsh plugin contributes exactly one top-level node_modules entry (its
# npm package name, e.g. `dsh-process-tree`); the base — the @deepseek-ai/dsh
# core package plus its transitive deps — is one single store node_modules
# package. So dev-mounting swaps that one entry to point at an editable
# plugin package dir (package.json + lib/ from src); everything else falls
# through to the store, and the plugin's deps still resolve via
# --preserve-symlinks.
#
# Evaluate with nixpkgs' module system, e.g.
#   lib.evalModules { modules = [ module ]; specialArgs = { inherit pkgs buildProfile; }; }
#
# Result: config.build.profile (store-pinned) + config.build.devProfile (dev-aware).
{ config, lib, pkgs, buildProfile, ... }:
{
  options = {
    # --- plugin / bundle selection (the profile recipe) ---
    core = lib.mkOption {
      type = lib.types.package;
      description = "The dsh core package (mkCorePackage result).";
    };
    plugins = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Store-built dsh plugins (pluginSet.<name>).";
    };
    bundles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" ];
      description = "Cordis bundle names to activate in package.json's dsh.profile.bundles.";
    };
    piDependencies = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Pi-package dependency map for pi2dsh runtime discovery.";
    };

    # --- dsh manifest normalize guard ---
    # dsh rc.1 rewrites <profile>/package.json at load when a shipped-template
    # bundle tuple lacks dsh.profile.patchReload — through the provisioned store
    # symlink that write is EROFS. mkDsh bakes the shipped template value per
    # profile name (web = live, everything else startup); null omits the field.
    patchReload = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "live" "startup" ]);
      default = null;
      description = "dsh.profile.patchReload baked into the profile manifest.";
    };

    # --- dev-mount surface ---
    # keyed by the plugin's npm name (the top-level node_modules entry), e.g.
    #   devMounts."dsh-process-tree" = { src = "/abs/path/to/plugin/package"; };
    # `src` is an IMPURE string path (kept out of the nix store) — matched
    # plugins get that single node_modules entry swapped to point at src, so
    # editing its files hot-reloads. Default (unset) = pinned store plugin.
    devMounts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          src = lib.mkOption {
            type = lib.types.str;
            description = ''
              Absolute path to an editable plugin package dir (a dsh plugin
              source root containing package.json + lib/). Must be a plain
              string (not a nix <path>), so it is NOT copied into the store
              and can be symlinked live. Editing files under it hot-reloads
              with no nix rebuild.
            '';
          };
        };
      });
      default = { };
    };

    # --- derived outputs (read-only) ---
    build.profile = lib.mkOption {
      type = lib.types.unspecified;
      readOnly = true;
      description = "Store-pinned dsh profile (buildProfile result).";
    };
    build.devOverlay = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "Dev overlay derivation: out/lib/node_modules/<name> are leaf symlinks to each devMount's editable src.";
    };
    build.devProfile = lib.mkOption {
      type = lib.types.unspecified;
      readOnly = true;
      description = "Dev-aware dsh profile: devOverlay folded first into buildProfile, so each devMounted node_modules entry points at src. Identical to build.profile when devMounts = {}.";
    };
  };

  config = {
    # Dev overlay: one plugin-shaped derivation whose out/lib/node_modules/<name>
    # are LEAF symlinks to each devMount's editable src. The src is a plain impure
    # string (not a nix <path>), so the symlink target is the out-of-store file
    # — editing its contents hot-reloads with no nix rebuild. Empty when
    # devMounts = {} (the runCommand just creates an empty lib/node_modules dir).
    build.devOverlay = pkgs.runCommand "dsh-dev-overlay" { } (
      ''
        mkdir -p $out/lib/node_modules
      '' + lib.concatStrings (
        lib.mapAttrsToList
          (name: v: "\n  mkdir -p \"$out/lib/node_modules/$(dirname ${lib.escapeShellArg name})\"\n  ln -s ${lib.escapeShellArg v.src} \"$out/lib/node_modules/${name}\"")
          config.devMounts)
    );
    # Store-pinned profile — buildProfile is pure and never sees dev srcs.
    build.profile = buildProfile {
      core = config.core;
      plugins = config.plugins;
      bundles = config.bundles;
      piDependencies = config.piDependencies;
      patchReload = config.patchReload;
    };
    # Dev-aware profile: devOverlay folded in FIRST so buildProfile's symlinkJoin
    # merges first-wins ⇒ each devMounted node_modules/<name> → src. When
    # devMounts = {} the devOverlay contributes nothing and this ≡ build.profile.
    build.devProfile = buildProfile {
      core = config.core;
      plugins = [ config.build.devOverlay ] ++ config.plugins;
      bundles = config.bundles;
      piDependencies = config.piDependencies;
      patchReload = config.patchReload;
    };
  };
}
