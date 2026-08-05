{
  pkgs,
  lib,
  std,  # Require nix-std
  ...
}:
let
  inherit (lib)
    mkOption
  ;

  inherit (lib.types)
    str
    path
    submodule
    attrsOf
  ;

  toml = pkgs.formats.toml {};

  tomlType = { name, config, ... }: {
    options = {
      name = mkOption {
        type = str;
        default = "${name}.toml";
      };
      content = mkOption {
        type = attrsOf toml.type;
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
      path = toml.generate config.name config.content;
      text = std.serde.toTOML config.content;
    };
  };
in {
  options.utils.toml = mkOption {
    type = attrsOf (submodule tomlType);
    default = {};
  };
}
