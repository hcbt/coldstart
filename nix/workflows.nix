# The workflows this repo owns, as text for `repo.extraFiles`.
#
# nivis generates `.envrc`, dependabot, release-please and the flake.lock
# workflow; these are the ones only this repo has. Routing them through
# `extraFiles` means one writer and one drift check for every workflow rather
# than half of them, so nothing here can be edited in `.github/` and quietly
# diverge from its source.
#
# Kept as verbatim YAML under `nix/ci/` rather than as Nix strings: this file
# contains `'${{ … }}'`, and a quote directly before an interpolation cannot be
# expressed in a Nix indented string without ambiguity. `nix/ci/` is excluded
# from treefmt, since prettier would otherwise reformat the source while the
# generated copy stays excluded — leaving the two permanently unequal.
{ }:
{
  ".github/workflows/build-push-image.yml" = builtins.readFile ./ci/build-push-image.yml;
}
