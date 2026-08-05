{ pkgs, lib, ... }:
let
  inherit (lib)
    mkOption
    generators
    concatStringsSep
    mapAttrs
  ;

  inherit (lib.types)
    str
    path
    submodule
    attrsOf
  ;

  atomToString = value:
    if value == null then ""
    else if builtins.isString value then value
    else builtins.toJSON value;

  listToValue = values:
    concatStringsSep ":" (map atomToString values);

  mkKeyValue = key: value:
    "${key}=${builtins.toJSON (
      if value == null then "" else value
    )}";

  dotenvCfg = {
    inherit listToValue mkKeyValue;
  };

  dotenv = pkgs.formats.keyValue dotenvCfg;

  isValidKey = key:
    builtins.match "[A-Za-z_][A-Za-z0-9_]*" key != null;

  validateContent = content:
    let
      invalidKeys = builtins.filter
        (key: ! isValidKey key)
        (builtins.attrNames content);
    in
      if invalidKeys == []
      then content
      else throw ''
        Invalid dotenv variable name(s): ${builtins.toJSON invalidKeys}.
        Names must match [A-Za-z_][A-Za-z0-9_]*.
      '';

  render = content:
    generators.toKeyValue { inherit mkKeyValue; } (
      mapAttrs (_: value:
        if builtins.isList value
        then listToValue value
        else value
      ) content
    );

  dotenvType = { name, config, ... }: {
    options = {
      name = mkOption {
        type = str;
        default = "${name}.env";
      };
      content = mkOption {
        type = dotenv.type;
        default = {};
        apply = validateContent;
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
      path = dotenv.generate config.name config.content;
      text = render config.content;
    };
  };
in {
  options.utils.dotenv = mkOption {
    type = attrsOf (submodule dotenvType);
    default = {};
  };
}
