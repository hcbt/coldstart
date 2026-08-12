# The dev shell, the formatters and the git hooks. Replaces nivis'
# `mkDevShell`, `flakeModules.git-hooks` and `flakeModules.treefmt`.
#
# There is no flake.nix. This file is the whole definition: the shell, the
# hooks, the chart, the reference image and every check. It is loaded by `devenv.lib.mkShell` in flake.nix, so
# the inputs come from there and there is no devenv.yaml.
#
# `nix develop` is impure: it PREPENDS the shell's packages to the ambient PATH
# rather than replacing it, so any tool not named here falls through to a
# Homebrew or /usr/bin copy without saying so. That is why the everyday
# utilities are pinned alongside the chart tooling.
{
  pkgs,
  lib,
  inputs,
  ...
}:
let
  # The set the chart and the reference image are BUILT from. devenv rides its
  # own channel so its Rust binaries stay cached; the two must not be confused.
  projectPkgs = import inputs.nixpkgs-project { inherit (pkgs.stdenv.hostPlatform) system; };
in
{
  packages = [
    # Everyday utilities, so nothing resolves to a host binary.
    pkgs.git
    pkgs.gh
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.findutils
    pkgs.curl

    # Repo-specific: the chart tooling.
    pkgs.kubernetes-helm
    pkgs.kubectl
    pkgs.kubeconform
    pkgs.yq-go
  ];

  # treefmt is gone. devenv's git-hooks IS cachix/git-hooks.nix, the project
  # nivis wrapped, and it carries nixfmt and prettier as hooks of their own —
  # so one formatter definition survives without the extra input.
  #
  # What is lost with treefmt: `nix fmt`. Formatting the whole tree is
  # `prek run --all-files` from inside the shell, and `checks.pre-commit` runs
  # the same hooks in CI.
  git-hooks.hooks = {
    # nixfmt is the RFC 166 formatter.
    nixfmt-rfc-style.enable = true;
    nixfmt-rfc-style.package = pkgs.nixfmt;
    prettier.enable = true;
    prettier.package = pkgs.prettier;

    # Correctness checks that are not formatting.
    check-merge-conflicts.enable = true;
    check-added-large-files.enable = true;

    # Helm templates are Go-templated YAML and are not YAML until rendered.
    check-yaml.enable = true;
    check-yaml.excludes = [ "^chart/templates/" ];

    # No formatter knows about a .gitignore, and a missing trailing newline
    # shows up as a spurious diff line in every later change to the file.
    end-of-file-fixer.enable = true;
    trim-trailing-whitespace.enable = true;
  };

  git-hooks.excludes = [
    "^LICENSE$"
    "\\.lock$"
    # prettier cannot parse `{{ … }}`.
    "^chart/templates/"
  ];

  # No `enterTest`. devenv 2.1.2 does not pick that option up — a run logs
  # `devenv:enterTest (no command)` and then reports "Tests passed", so an
  # assertion written there passes whether or not it ran. Measured on the
  # self-hosted runner, not assumed. The real assertions are in nix/checks.nix.

  # --------------------------------------------------------- what it builds
  #
  # `packages` and `checks` both become `outputs`. A check here was always a
  # derivation, so building one IS running it.
  outputs =
    import ./nix/packages.nix { } {
      pkgs = projectPkgs;
      inherit lib;
    }
    // import ./nix/checks.nix { inherit inputs; } {
      pkgs = projectPkgs;
      inherit lib;
    };

  # The reference image, through this repository's OWN devenv module — the same
  # one consumers import. Dogfooding it is what keeps the module honest now
  # that `checks.flake-module` and `checks.example-flake` are gone with the
  # flake. An exported module with no consumer test is how the flake-parts one
  # would have rotted.
  coldstart.images.reference-app = {
    name = "reference-app";
    entrypoint = [ "/bin/sh" ];
  };
}
