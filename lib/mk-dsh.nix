# lib/mk-dsh.nix — thin dsh wrapper builder.
#
# Produces a SINGLE `dsh` app (thin wrapper) that, at startup:
#   (a) injects the daemon env (DSH_HOME, PI_FFF_MODE, …),
#   (b) idempotently provisions the long-lived DSH_HOME symlink forest, and
#   (c) `exec`s the real core binary.
#
# Config-source modes — the homeConfig binding form IS the mode switch:
#   dev     — homeConfig given as an OUT-OF-STORE absolute path STRING
#             (e.g. "/abs/path/to/config"): every
#             config-class link points at the hot-editable working tree.
#   release — homeConfig given as a Nix PATH (e.g. ./config): evaluation bakes
#             it into the store, links point at the immutable copy, and
#             settings.yaml becomes RUNTIME STATE (seeded once from the baked
#             copy, never touched by later provisions).
# Branching is automatic: any /nix/store/… source ⇒ release semantics.
#
# Provision conflict matrix — applied UNIFORMLY to every managed link:
#   destination missing             → create symlink
#   destination is a symlink        → idempotent relink (ln -sfn)
#   real file, content == source    → silent replace with symlink
#   real file, content != source    → HARD ERROR, refuse to start
#   (source missing                 → warn + skip)
# Rationale: the daemon persists settings via atomic rename, which REPLACES a
# symlinked target itself instead of writing through it. A blind relink would
# silently discard those runtime edits; surfacing the divergence lets a human
# resolve it instead.
#
# The old new-home / dev-mount / dev-unmount scripts are absorbed into this
# startup provision, so only ONE `dsh` app is exposed. Symlinks are NEVER
# unlinked on shutdown: they point at immutable paths, so leaving them is
# side-effect-free. A separate optional `dsh-unlink` app removes them on
# demand (NOT a `dsh` subcommand) — it deliberately leaves settings.yaml
# alone: in release mode that file is user state, not a managed link.
#
# Dev-mount granularity = the whole node_modules entry as a permanent
# directory symlink. When devMounts != {}, each profile's node_modules is
# pointed at the dev-aware profile whose dev-mounted entries are leaf symlinks
# to the editable src checkout; editing src hot-reloads.
{ pkgs, lib, evalProfileModule }:
{ core
, plugins            # list (shared across profiles) OR attrset { web = [...]; headless = [...] }
, bundles            # attrset keyed by profile name: { web = [...]; headless = [...] }
, piDependencies ? { }
, devMounts ? { }
, homeConfig         # OUT-OF-STORE abs path STRING (dev) or Nix PATH baked into store (release)
, extraEnv ? { }
, homeDir ? null
}:
let
  # profile names come from the bundles attrset keys
  profileNames = builtins.attrNames bundles;

  # evaluate the reusable dsh profile module per profile
  evals = lib.genAttrs profileNames (name:
    evalProfileModule {
      inherit core piDependencies devMounts;
      plugins = if lib.isList plugins
                then plugins
                else (if builtins.hasAttr name plugins then plugins.${name} else [ ]);
      bundles = bundles.${name};
    });

  # dev-aware resolution: when devMounts is non-empty, point at the dev profile
  # whose dev-mounted node_modules entries are leaf symlinks to editable src.
  resolved = name:
    if devMounts != { } then evals.${name}.devProfile else evals.${name}.profile;

  # DSH_HOME precedence: explicit extraEnv.DSH_HOME, then an explicit
  # homeDir, then a portable default resolved at RUNTIME by the generated
  # shell (<$HOME>/.dsh) — no machine-specific path is ever baked in.
  dshHome = if extraEnv ? DSH_HOME then extraEnv.DSH_HOME
            else if homeDir != null then homeDir
            else null;
  piFffMode = if extraEnv ? PI_FFF_MODE then extraEnv.PI_FFF_MODE else "override";

  # Shell-level DSH_HOME fallback shared by `dsh` and `dsh-unlink`: the
  # configured value if any, else a runtime-resolved <$HOME>/.dsh.
  homeDefaultExpr = if dshHome != null then lib.escapeShellArg dshHome
                    else "\${HOME:-/root}/.dsh";

  # (a) env exports — DSH_HOME / PI_FFF_MODE carry defaults + override
  # precedence; everything else in extraEnv is passed through verbatim.
  finalEnv = extraEnv // (lib.optionalAttrs (dshHome != null) { DSH_HOME = dshHome; }) // {
    PI_FFF_MODE = piFffMode;
  };
  envExports = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") finalEnv
  );

  # Config-source mode: a Nix path (or explicit store path string) resolves
  # into /nix/store ⇒ release semantics; anything else ⇒ dev.
  cfgStr = toString homeConfig;
  isBaked = lib.hasPrefix "/nix/store/" cfgStr;

  cfg = lib.escapeShellArg cfgStr;
  dshBin = lib.escapeShellArg "${core}/bin/dsh";
  # pinned so the matrix works regardless of the invoker's PATH
  cmpBin = lib.escapeShellArg "${pkgs.diffutils}/bin/cmp";

  # (b) per-profile node_modules + package.json links go through the same
  # conflict matrix as everything else. cordis.yml is LOCAL STATE in every
  # mode — created as a placeholder, never linked, never clobbered.
  profileLinkBlock = lib.concatStringsSep "\n" (map (name:
    let p = resolved name; in
    ''
      mkdir -p "$HOME_DIR/profiles/${name}"
      provision_link ${lib.escapeShellArg "${p}/node_modules"} "$HOME_DIR/profiles/${name}/node_modules"
      provision_link ${lib.escapeShellArg "${p}/package.json"} "$HOME_DIR/profiles/${name}/package.json"
      [[ -f "$HOME_DIR/profiles/${name}/cordis.yml" ]] || printf '[]\n' > "$HOME_DIR/profiles/${name}/cordis.yml"
    '') profileNames);

  # agent-presets (optional config layer, discovered at runtime so the flake
  # stays decoupled from the filesystem)
  agentPresetBlock = ''
    if [[ -d ${cfg}/agent-presets ]]; then
      mkdir -p "$HOME_DIR/.agent-presets"
      for _p in "${cfg}"/agent-presets/*; do
        [[ -d "$_p" ]] || continue
        _pn="$(basename "$_p")"
        mkdir -p "$HOME_DIR/.agent-presets/$_pn"
        for _f in preset.yml agent.cordis.yml; do
          if [[ -f "$_p/$_f" ]]; then
            provision_link "$_p/$_f" "$HOME_DIR/.agent-presets/$_pn/$_f"
          fi
        done
      done
    fi
  '';

  wrapper = pkgs.writeShellScriptBin "dsh" (''
    set -euo pipefail

    # (a) inject daemon env
    ${envExports}

    # DSH_HOME: an explicit value was exported above and wins; when none was
    # configured, resolve a portable default (<$HOME>/.dsh) at runtime so no
    # machine-specific path is ever baked into the wrapper.
    export DSH_HOME="''${DSH_HOME:-${homeDefaultExpr}}"

    HOME_DIR="$DSH_HOME"
    mkdir -p "$HOME_DIR"

    # provision_link SRC DST — the managed-link conflict matrix (file header).
    # Never destroys divergent content: it refuses to start instead.
    provision_link() {
      local _src="''${1:?}" _dst="''${2:?}"
      if [[ ! -e "$_src" ]]; then
        echo "dsh provision: WARN: source missing, skipping: $_src" >&2
        return 0
      fi
      if [[ -L "$_dst" ]]; then
        ln -sfn "$_src" "$_dst"
      elif [[ ! -e "$_dst" ]]; then
        ln -s "$_src" "$_dst"
      elif [[ -f "$_dst" ]] && ${cmpBin} -s "$_dst" "$_src"; then
        ln -sfn "$_src" "$_dst"       # identical real file: safe to swap
      else
        echo "dsh provision: CONFLICT: '$_dst' exists and differs from '$_src'" >&2
        echo "dsh provision: keep one side / merge by hand, then re-run." >&2
        exit 1
      fi
    }

    # (b) idempotent provision — every managed link goes through the matrix
    ${profileLinkBlock}

    # config layer
'' + (if isBaked then ''
    # release mode: settings.yaml is runtime state — seed once, then hands off
    if [[ ! -e "$HOME_DIR/settings.yaml" && -f ${cfg}/settings.yaml ]]; then
      cp ${cfg}/settings.yaml "$HOME_DIR/settings.yaml"
    fi
'' else ''
    # dev mode: settings stay a hot-editable out-of-store link
    provision_link ${cfg}/settings.yaml "$HOME_DIR/settings.yaml"
'') + ''
    provision_link ${cfg}/patch.yml "$HOME_DIR/cordis.patch.yml"
    provision_link ${cfg}/gitignore "$HOME_DIR/.gitignore"
    if [[ -f ${cfg}/web/cordis.patch.yml ]]; then
      provision_link ${cfg}/web/cordis.patch.yml "$HOME_DIR/profiles/web/cordis.patch.yml"
    fi
    if [[ -f ${cfg}/headless/cordis.patch.yml ]]; then
      provision_link ${cfg}/headless/cordis.patch.yml "$HOME_DIR/profiles/headless/cordis.patch.yml"
    fi

    # agent-presets (optional)
    ${agentPresetBlock}

    # secrets (perms 600) — never clobber existing secrets
    touch "$HOME_DIR/.credentials.yaml" "$HOME_DIR/.env"
    chmod 600 "$HOME_DIR/.credentials.yaml" "$HOME_DIR/.env"

    # (c) exec the real dsh core (its bin already carries --preserve-symlinks)
    exec ${dshBin} "$@"
  '');

  # Optional manual teardown — NOT a `dsh` subcommand. Leaves settings.yaml,
  # cordis.yml, credentials and .env alone: those are user/runtime state.
  unlink = pkgs.writeShellScriptBin "dsh-unlink" ''
    set -euo pipefail
    HOME_DIR="''${DSH_HOME:-${homeDefaultExpr}}"
    for prof in ${lib.escapeShellArg (builtins.concatStringsSep " " profileNames)}; do
      rm -f "$HOME_DIR/profiles/$prof/node_modules" "$HOME_DIR/profiles/$prof/package.json"
    done
    rm -f "$HOME_DIR/cordis.patch.yml" "$HOME_DIR/.gitignore"
    rm -f "$HOME_DIR/profiles/web/cordis.patch.yml" "$HOME_DIR/profiles/headless/cordis.patch.yml"
    rm -f "$HOME_DIR/.agent-presets"/*/preset.yml "$HOME_DIR/.agent-presets"/*/agent.cordis.yml
    echo "removed dsh-managed symlinks from $HOME_DIR"
  '';
in
{
  packages = {
    dsh = wrapper;
    dsh-unlink = unlink;
  } // lib.genAttrs profileNames (name: resolved name);
  apps = {
    dsh = { type = "app"; program = "${wrapper}/bin/dsh"; };
    dsh-unlink = { type = "app"; program = "${unlink}/bin/dsh-unlink"; };
  };
}
