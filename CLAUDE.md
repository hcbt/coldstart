# CLAUDE.md

coldstart is generic scaffolding for running a Nix-built workload as a
container — an OCI image plus Helm chart for Kubernetes, and a systemd-nspawn
NixOS container for an existing host. It has no workload of its own: the
deliverable _is_ the module set and the chart, so a change here is a change to
every consumer's deploy.

## Layout

- `nix/image.nix` — the generic OCI image. A plain function of `pkgs`, with no
  flake, no flake-parts and no `self`, so a consumer builds it against its own
  nixpkgs rather than inheriting this repo's pin.
- `nix/image-shims.nix` — the pieces a from-scratch Nix image is missing.
  Separate from `image.nix` so checks can RUN them without building an image.
- `nix/flake-module.nix` — `perSystem.coldstart.images.<name>`, one package each.
- `nix/nixos-module.nix` — `coldstart.containers.<name>`, the nspawn half.
- `nix/lib.nix` — the public surface: `lib.mkImage`, `lib.renderChart`,
  `lib.chart`, `flakeModules.default`, `nixosModules.default`.
- `chart/` — the Kubernetes half.
- `examples/` — evaluated by `checks.example-flake` and rendered by
  `checks.chart-render-example`, so both are tested rather than decorative.

## Invariants

- **Defaults are decisions, and each one is argued for in a comment.**
  `nixStore.enabled = false`, no `fsGroup`, `strategy: Recreate`,
  `openFirewall = false`, `ephemeral = true` — every one of those has a failure
  mode behind it that is documented where the value is set. Changing one means
  changing the argument, not just the value.
- **The two container paths share only the workload package.** The nspawn
  container gets the host's store by bind mount; it must never grow a
  dependency on the OCI image, and the chart must never grow one on NixOS.
- **`nix flake check` does not look at `flake.lib`, `flake.flakeModules` or
  `flake.nixosModules`** ("The following flake outputs are unchecked"). The
  consumer-facing surface is only covered because `checks.flake-module`,
  `checks.nixos-module` and `checks.example-flake` evaluate it explicitly. A
  new public output needs a new check or nothing tests it.
- **Assert with yq on rendered YAML, never grep.** The templates carry long
  comments that survive into the output, so a grep for `hostPort` matches the
  comment about host ports whether or not the field is there.
- **A `select()` that matches nothing renders as `""`, not `null`.** `null` is
  what an absent _field_ renders as. Getting this backwards writes an assertion
  that passes no matter what the chart does.
- **Linux-only checks are guarded by `pkgs.stdenv.hostPlatform.isLinux`.**
  dockerTools cannot build a Linux image from Darwin, so `image-evaluates`,
  `nixos-module` and `packages.example-image` only exist where they can run.
  `nix flake check` on a laptop silently omits them — verify on Linux before
  claiming an image change works.

## Shared scaffolding

The dev shell, treefmt, the git hooks and the GitHub-side files come from
[nivis](https://github.com/hcbt/nivis), pinned in `flake.nix`.

- **Do not add a treefmt or git-hooks module here.** nivis brings nixfmt,
  prettier and the language-agnostic hook set; `nix/format.nix` adds only the
  Helm exclusions.
- **`.envrc`, `.github/dependabot.yml`, `release-please-config.json` and the
  `Check`, `Update flake.lock` and release-please workflows are generated.**
  Edit them in nivis, then run `nix run .#sync-repo` here.
  `checks.repo-files-current` fails on drift.
- `.github/workflows/build-push-image.yml` is this repo's own and is **not**
  generated — it is the reusable workflow consumers call.
- Releases come from release-please. Do not tag by hand.

## Working on this repo

- New files must be `git add`ed before any `nix` command sees them.
- Helm templates are not YAML. Both prettier and the `check-yaml` hook exclude
  `chart/templates/` — Go template directives do not parse.
- The chart is consumed by ArgoCD **directly from this repository's `chart/`
  path**, so a breaking template change reaches production as soon as it lands
  on master. There is no version pin between a consumer's values and this
  chart; add a value's default rather than requiring consumers to set it.
