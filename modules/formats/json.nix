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

  json = pkgs.formats.json {};

  jsonType = { name, config, ... }: {
    options = {
      name = mkOption {
        type = str;
        default = "${name}.json";
      };
      content = mkOption {
        type = json.type;
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
      path = json.generate config.name config.content;
      text = generators.toJSON {} config.content;
    };
  };
in {
  options.utils.json = mkOption {
    type = attrsOf (submodule jsonType);
    default = {};
  };
}
