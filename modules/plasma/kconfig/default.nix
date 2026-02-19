{ lib, pkgs, ... }:
let
  inherit (lib)
    mkOption
    types
  ;

  inherit
    (import ./types.nix { inherit lib pkgs; })
    fileType
  ;
in {
  options.utils.kconfig = mkOption {
    type = types.attrsOf fileType;
    default = {};
    description = "attrset of KDE configuration files";
  };
}
