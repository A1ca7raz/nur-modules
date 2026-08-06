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

  json = pkgs.formats.json {};

  inherit (import ./secrets-replacement.nix { inherit lib pkgs; })
    genSecretsReplacementSnippet
  ;

  jsonType = { name, config, ... }:
    let
      templatePath = json.generate config.name config.content;
    in {
      options = {
        name = mkOption {
          type = str;
          default = "${name}.json";
        };
        content = mkOption {
          type = json.type;
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
        text = generators.toJSON {} config.content;
        script = if config.enableSecretsReplacement
          then genSecretsReplacementSnippet {
            format = "json";
            content = config.content;
            input = templatePath;
            output = config.path;
          }
          else "";
      };
    };
in {
  options.utils.json = mkOption {
    type = attrsOf (submodule jsonType);
    default = {};
  };
}
