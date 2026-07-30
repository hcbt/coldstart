# The repo-specific half of formatting and hooks. nivis brings nixfmt, prettier
# and the language-agnostic hook set; the module system merges what is here on
# top, so nothing nivis already set has to be restated.
{ ... }:
{
  perSystem = {
    treefmt.settings.global.excludes = [
      "LICENSE"
      # Helm templates are Go-templated YAML; prettier cannot parse `{{ … }}`.
      "chart/templates/*"
    ];

    # Helm templates are not YAML until rendered.
    pre-commit.settings.hooks.check-yaml.excludes = [ "^chart/templates/" ];
  };
}
