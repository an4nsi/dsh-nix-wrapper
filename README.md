# dsh-nix-wrapper

Reusable dsh **profile module** + thin **dsh wrapper builder** for Nix consumers
who want to compose their own [DeepSeek Harness](https://github.com/deepseek-ai/dsh)
(web/headless) setup out of a flake — the same idea as
[nvim-inogai](https://github.com/inogai/nvim-inogai) / nix-wrapper-modules.

Sibling repo: [`dsh-nix-packages`](https://github.com/an4nsi/dsh-nix-packages)
supplies the dsh **core** and the **plugins** (each a derivation whose
`out/lib/node_modules/<name>` is the flat entry the dsh profile expects).
Consumers wire both as flake inputs.

## What's here

- **`modules.default`** — the reusable dsh profile module. Import it into the
  nixpkgs module system and set options:
  - `core` — the dsh core package (from `dsh-nix-packages`),
  - `plugins` — store-built dsh plugins,
  - `bundles` — cordis bundle names to activate
    (default `["@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app"]`),
  - `piDependencies` — Pi-package dependency map for pi2dsh runtime discovery,
  - `devMounts` — point any plugin at an editable, out-of-store source path so
    its files hot-reload with no nix rebuild (granularity = one top-level
    node_modules entry per mount).
- **`lib.<sys>.evalProfileModule`** — evaluate `./module.nix` against a recipe,
  returns `{ profile, devProfile, config }`.
- **`lib.<sys>.buildProfile`** — assemble a flat node_modules + package.json
  profile from a core + plugin list (pure `{ lib, pkgs }`).
- **`lib.<sys>.mkDsh`** — the thin `dsh` wrapper builder: injects daemon env
  (`DSH_HOME`, …), idempotently provisions the long-lived DSH_HOME symlink
  forest on startup, and removes managed links on teardown. Phase-1 refactor
  target: the old `new-home` / `dev-mount` / `dev-unmount` scripts of the
  deployment flake (the end-user flake that consumes this wrapper and builds
  its `dsh` app) are absorbed into this single wrapper's startup provision.
  Since dsh rc.1, each profile's node_modules is provisioned as a real
  per-entry-linked directory (writable for dsh's module-fallback healing)
  instead of a single store symlink — see lib/mk-dsh.nix.

## Quickstart

```nix
# flake.nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  dsh-nix-packages.url = "github:an4nsi/dsh-nix-packages";
  dsh-nix-wrapper.url = "github:an4nsi/dsh-nix-wrapper";
};
outputs = { self, nixpkgs, dsh-nix-packages, dsh-nix-wrapper, ... }: let
  system = "x86_64-linux";
  pkgs = nixpkgs.legacyPackages.${system};
  core = dsh-nix-packages.packages.${system}.core;
  plugins = with dsh-nix-packages.packages.${system}; [ pi2dsh dsh-better-sidebar ];
  result = dsh-nix-wrapper.lib.${system}.mkDsh {
    inherit core plugins;
    bundles = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" ];
  };
in {
  packages.${system}.dsh = result.packages.dsh;   # deployment wrapper
  # ... result.packages.dsh-dev / dsh-unlink / web / headless as needed
};
```

See `dsh-nix-packages`' README for the full plugin list.
