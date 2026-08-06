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
    bool
    submodule
    attrsOf
  ;

  toml = pkgs.formats.toml {};

  inherit (import ./secrets-replacement.nix { inherit lib pkgs; })
    genSecretsReplacementSnippet
  ;

  tomlType = { name, config, ... }:
    let
      templatePath = toml.generate config.name config.content;
    in {
      options = {
        name = mkOption {
          type = str;
          default = "${name}.toml";
        };
        content = mkOption {
          type = attrsOf toml.type;
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
        text = std.serde.toTOML config.content;
        script = if config.enableSecretsReplacement
          then genSecretsReplacementSnippet {
            format = "toml";
            content = config.content;
            input = templatePath;
            output = config.path;
          }
          else "";
      };
    };
in {
  options.utils.toml = mkOption {
    type = attrsOf (submodule tomlType);
    default = {};
  };
}
