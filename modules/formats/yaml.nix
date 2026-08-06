{ pkgs, lib, ... }:
let
  inherit (lib)
    mkOption
    generators
  ;

  inherit (lib.types)
    str
    bool
    submodule
    attrsOf
  ;

  yaml = pkgs.formats.yaml_1_2 {};

  inherit (import ./secrets-replacement.nix { inherit lib pkgs; })
    genSecretsReplacementSnippet
  ;

  yamlType = { name, config, ... }:
    let
      templatePath = yaml.generate config.name config.content;
    in {
      options = {
        name = mkOption {
          type = str;
          default = "${name}.yaml";
        };
        content = mkOption {
          type = yaml.type;
          default = {};
        };
        enableSecretsReplacement = mkOption {
          type = bool;
          default = false;
        };
        path = mkOption {
          type = str;
          default = toString templatePath;
        };
        text = mkOption {
          type = str;
          readOnly = true;
        };
        script = mkOption {
          type = str;
          readOnly = true;
        };
      };

      config = {
        text = generators.toYAML {} config.content;
        script = if config.enableSecretsReplacement
          then genSecretsReplacementSnippet {
            format = "yaml";
            content = config.content;
            input = templatePath;
            output = config.path;
          }
          else "";
      };
    };
in {
  options.utils.yaml = mkOption {
    type = attrsOf (submodule yamlType);
    default = {};
  };
}
