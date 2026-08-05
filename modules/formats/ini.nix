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

  ini = pkgs.formats.ini {};

  iniType = { name, config, ... }: {
    options = {
      name = mkOption {
        type = str;
        default = "${name}.ini";
      };
      content = mkOption {
        type = ini.type;
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
      path = ini.generate config.name config.content;
      text = generators.toINI {} config.content;
    };
  };
in {
  options.utils.ini = mkOption {
    type = attrsOf (submodule iniType);
    default = {};
  };
}
