{ pkgs, lib, ... }:
let
  inherit (lib)
    mkOption
    generators
  ;

  inherit (lib.types)
    str
    path
    submodule
    attrsOf
  ;

  yaml = pkgs.formats.yaml_1_2 {};

  yamlType = { name, config, ... }: {
    options = {
      name = mkOption {
        type = str;
        default = "${name}.yaml";
      };
      content = mkOption {
        type = yaml.type;
        default = {};
      };
      path = mkOption {
        type = path;
        readOnly = true;
      };
      text = mkOption {
        type = str;
        readOnly = true;
      };
    };

    config = {
      path = yaml.generate config.name config.content;
      text = generators.toYAML {} config.content;
    };
  };
in {
  options.utils.yaml = mkOption {
    type = attrsOf (submodule yamlType);
    default = {};
  };
}
