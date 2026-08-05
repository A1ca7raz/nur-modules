# https://github.com/nix-community/plasma-manager/blob/d226a67fdf835be15e5270c36406e922f4b6fa84/lib/types.nix
{ lib, pkgs }:
let
  inherit (lib)
    types
    mkOption
    getExe
  ;

  inherit (types)
    nullOr
    oneOf
    bool
    float
    int
    str
    submodule
    coercedTo
    attrsOf
    submoduleWith
    path
    package
  ;

  inherit (import ./lib.nix { inherit pkgs; })
    writeConfigScript
    writeConfig
  ;
in rec {
  ##############################################################################
  # Types for storing settings.
  basicSettingsType = (
    nullOr (oneOf [
      bool
      float
      int
      str
    ])
  );

  advancedSettingsType = submodule {
    options = {
      value = mkOption {
        type = basicSettingsType;
        default = null;
        description = "The value for some key.";
      };
      immutable = mkOption {
        type = bool;
        default = false;
        description = ''
          Whether to make the key immutable. This corresponds to adding [$i] to
          the end of the key.
        '';
      };
      shellExpand = mkOption {
        type = bool;
        default = false;
        description = ''
          Whether to mark the key for shell expansion. This corresponds to
          adding [$e] to the end of the key.
        '';
      };
      persistent = mkOption {
        type = bool;
        default = false;
        description = ''
          When overrideConfig is enabled and the key is persistent,
          plasma-manager will leave it unchanged after activation.
        '';
      };
      escapeValue = mkOption {
        type = bool;
        default = true;
        description = ''
          Whether to escape the value according to kde's escape-format. See:
          https://invent.kde.org/frameworks/kconfig/-/blob/v6.7.0/src/core/kconfigini.cpp?ref_type=tags#L880-945
          for info about this format.
        '';
      };
      escapeKey = mkOption {
        type = bool;
        default = false;
      };
    };
  };

  coercedSettingsType =
    coercedTo basicSettingsType (value: { inherit value; }) advancedSettingsType;

  fileModule = { name, config, ... }: {
    options = {
      content = mkOption {
        type = attrsOf (attrsOf coercedSettingsType);
        default = {};
      };

      script = mkOption {
        type = package;
        default = writeConfig name config.content;
        visible = false;
        readOnly = true;
      };

      path = mkOption {
        type = path;
        visible = false;
        readOnly = true;
      };
    };

    config.path = pkgs.runCommand name {
      nativeBuildInputs = [
        config.script
      ];
    } "${lib.getExe config.script} $out";
  };

  fileType = submoduleWith {
    modules = [ fileModule ];
    shorthandOnlyDefinesConfig = true;
  };
}
