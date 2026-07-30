# A Nix-built OCI image for an arbitrary workload.
#
# A plain function of `pkgs` and nothing else — no flake, no flake-parts, no
# `self`. That is deliberate: a consumer flake can call it with its own nixpkgs
# and get an image built against the exact package set the rest of its build
# uses, without inheriting this repo's nixpkgs pin.
#
#   coldstart.lib.mkImage { inherit pkgs; name = "my-app"; packages = [ … ]; }
#
# What this adds on top of `dockerTools.buildLayeredImage` is everything a
# from-scratch Nix image is MISSING rather than gets wrong: /usr/bin/env, an
# /etc/passwd entry for the uid the container runs as, a registered Nix
# database, a nix.conf that works without a build-users group, and TLS roots.
# Each absence is invisible at build time and costs a full deploy round-trip to
# find, which is why they are defaults here instead of a checklist.
{
  pkgs,

  # Image name and tag. The tag is normally left at `latest` and the real
  # versioning is done by whatever publishes the image (a commit-SHA tag, an
  # ArgoCD image updater tracking the digest of `latest`, …).
  name ? "coldstart",
  tag ? "latest",

  # The workload. Everything else here is scaffolding around whatever goes in
  # this list.
  packages ? [ ],

  # Toolchain the workload shells out to, on top of `basePackages` below.
  extraPackages ? [ ],

  # The base set: what a shell command in a container assumes exists. Set to
  # `[ ]` for a genuinely minimal image — nothing below depends on it except
  # the `/bin/sh` most orchestrators use to run a command.
  basePackages ? [
    pkgs.bashInteractive
    pkgs.coreutils-full
    pkgs.findutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gnutar
    pkgs.gzip
  ],

  # Nix itself, plus the nix.conf below. Off for a workload that only needs to
  # RUN — it costs ~200M of closure and is only useful when the container
  # builds or realises derivations of its own.
  withNix ? true,

  # Seeds /nix/var/nix/db so `nix build` works inside the container; without it
  # the store paths are present but unregistered and every nix command fails.
  # Costs reproducibility (db.sqlite embeds timestamps) — usually worth it, and
  # meaningless when `withNix` is false.
  includeNixDB ? true,

  # Merged over the defaults, so a consumer can add substituters/keys or flip a
  # setting without restating the base. List values are joined with spaces,
  # bools rendered as true/false.
  nixSettings ? { },

  # skopeo lets a container push images to a registry with no Docker daemon.
  # Pulls in the trust policy below with it. Off by default: it is a CI
  # concern, not a general one.
  withSkopeo ? false,

  # TLS roots, and the two environment variables that point at them. Anything
  # reaching an https endpoint needs these; a from-scratch image has no
  # /etc/ssl at all and failures surface as opaque certificate errors.
  withCacert ? true,

  # Merged over the default environment; `null` removes a default entirely.
  env ? { },

  # OCI labels. Setting org.opencontainers.image.source to the repository URL is
  # what links a GHCR package to its repo, so the package inherits the repo's
  # permissions instead of needing access granted by hand.
  labels ? { },

  # The unprivileged user the image declares. Postgres' initdb (and anything
  # else that refuses to run as root) is the reason workloads do not run as
  # uid 0, and Nix needs the passwd entry to exist at all — see fakeNss below.
  user ? { },

  # The OCI entrypoint and command. Left null, the image declares neither and
  # whatever runs it supplies both — which is what the Helm chart in this repo
  # does. Set them for an image that is useful with `docker run` alone.
  entrypoint ? null,
  command ? null,

  # Ports the workload listens on, as dockerTools expects them:
  #   { "16261/udp" = { }; }
  # Purely declarative metadata — it publishes nothing by itself.
  exposedPorts ? { },

  # Working directory. Defaults to the user's home, which is the only directory
  # in the image guaranteed to be writable once a volume is mounted there.
  workingDir ? null,

  # Merged over the generated OCI `config` block, for the fields not given an
  # option above (Volumes, StopSignal, …).
  extraConfig ? { },

  # Extra store paths to include verbatim. The escape hatch for a package set
  # that has to be laid out at a specific path rather than merged into /bin.
  extraContents ? [ ],
}:
let
  inherit (pkgs) lib;

  # /usr/bin/env, and the skopeo trust policy. Both are things a from-scratch
  # Nix image is missing rather than things it gets wrong; image-shims.nix
  # explains each at length, and checks.nix executes them.
  shims = import ./image-shims.nix { inherit pkgs; };

  defaultUser = {
    name = "app";
    uid = 1000;
    gid = 1000;
    home = "/app";
    shell = "/bin/bash";
  };
  u = defaultUser // user;

  defaultNixSettings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # The container is the isolation boundary, so the build sandbox is
    # redundant — and there is only root inside it, so there are no build users
    # to hand a sandboxed build to.
    sandbox = false;
    build-users-group = "";
    substituters = [ "https://cache.nixos.org" ];
    trusted-public-keys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
  };

  renderSetting =
    v:
    if lib.isList v then
      lib.concatMapStringsSep " " toString v
    else if lib.isBool v then
      lib.boolToString v
    else
      toString v;

  # Substituters are declared in the image rather than by an action at runtime:
  # the usual tools for adding one (cachix's installer, for instance) run
  # `nix-env -iA` first, which does not work in a from-scratch Nix container.
  nixConf = pkgs.writeTextDir "etc/nix/nix.conf" (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "${k} = ${renderSetting v}") (defaultNixSettings // nixSettings)
    )
    + "\n"
  );

  defaultEnv = {
    PATH = "/bin";
    HOME = u.home;
    USER = u.name;
    TMPDIR = "/tmp";
  }
  // lib.optionalAttrs withCacert {
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    # For anything that honours the directory rather than the file. A vendored
    # binary that reads neither is covered by `shims.caCertCompat` instead.
    SSL_CERT_DIR = "/etc/ssl/certs";
  }
  // lib.optionalAttrs withSkopeo {
    # skopeo stores credentials under $XDG_RUNTIME_DIR (or /run/containers/$UID
    # when unset), and an unprivileged uid cannot create /run — `skopeo login`
    # dies with "mkdir /run: permission denied". Point both at the writable
    # home. XDG_RUNTIME_DIR is set too so other tools that expect it do not hit
    # the same wall.
    REGISTRY_AUTH_FILE = "${u.home}/.config/containers/auth.json";
    XDG_RUNTIME_DIR = "${u.home}/.run";
  };

  finalEnv = lib.filterAttrs (_: v: v != null) (defaultEnv // env);

  baseConfig = {
    Env = lib.mapAttrsToList (k: v: "${k}=${toString v}") finalEnv;
    WorkingDir = if workingDir != null then workingDir else u.home;
    Labels = labels;
  }
  // lib.optionalAttrs (entrypoint != null) { Entrypoint = entrypoint; }
  // lib.optionalAttrs (command != null) { Cmd = command; }
  // lib.optionalAttrs (exposedPorts != { }) { ExposedPorts = exposedPorts; };
in
pkgs.dockerTools.buildLayeredImage {
  inherit name tag;
  # Only meaningful alongside a Nix that could read the database.
  includeNixDB = withNix && includeNixDB;

  contents =
    packages
    ++ basePackages
    ++ [
      # /usr/bin/env, so a script carrying the portable shebang can exec.
      shims.usrBinEnv

      # /etc/passwd and /etc/group. Stock fakeNss only defines root and nobody —
      # with no entry for the uid the container runs as, Nix cannot resolve the
      # user and every nix command dies with "error: cannot determine user's
      # home directory". Plenty of non-Nix software fails the same way, more
      # quietly.
      (pkgs.dockerTools.fakeNss.override {
        extraPasswdLines = [
          "${u.name}:x:${toString u.uid}:${toString u.gid}:${u.name}:${u.home}:${u.shell}"
        ];
        extraGroupLines = [ "${u.name}:x:${toString u.gid}:" ];
      })
    ]
    # The bundle, plus the conventional paths a vendored binary's own OpenSSL
    # was compiled to look for — see image-shims.nix.
    ++ lib.optionals withCacert [
      pkgs.cacert
      shims.caCertCompat
    ]
    ++ lib.optionals withNix [
      pkgs.nix
      nixConf
    ]
    ++ lib.optionals withSkopeo [
      pkgs.skopeo
      shims.containersPolicy
    ]
    ++ extraPackages
    ++ extraContents;

  config = baseConfig // extraConfig;
}
