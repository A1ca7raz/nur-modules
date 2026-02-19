{ lib, config, ... }:
let
  inherit (lib)
    mkOption
    types
    mkIf
    foldlAttrs
    foldl
    mkItem
    optionals
    forEach
    convertItemsToKconfig
  ;

  inherit (builtins)
    concatStringsSep
  ;

  cfg = config.utils.plasma.monitors;

  optionInt = mkOption {
    type = with types; coercedTo int toString str;
  };

  optionStr = mkOption { type = types.str; };

  optionNullStr = mkOption {
    type = with types; nullOr str;
    default = null;
  };

  appletType = types.submodule (
    { name, ... }: {
      options = {
        id = optionInt;

        plugin = optionStr;

        config = mkOption {
          type = with types; attrsOf attrs;
          default = {};
        };
      };
    }
  );

  panelType = types.submodule (
    { config, ... }: {
      options = {
        id = optionInt;

        formfactor = optionInt // { default = "2"; };
        immutability = optionInt // { default = "1"; };
        lastScreen = optionInt;
        location = optionInt;
        plugin = optionStr // { default = "org.kde.panel"; };

        config = mkOption {
          type = with types; attrsOf attrs;
          default = {};
        };

        extraConfig = mkOption {
          type = with types; attrsOf attrs;
          default = {};
        };

        applets = mkOption {
          type = with types; listOf appletType;
          default = [];
        };
      };
    }
  );

  monitorType = types.submodule (
    { name, ... }: {
      options = {
        id = optionInt;
        activityId = optionStr // { default = "114514aa-bbcc-ddee-ff00-1919810abcde"; };
        formfactor = optionInt // { default = "0"; };
        immutability = optionInt // { default = "1"; };
        lastScreen = optionInt;
        location = optionInt // { default = "0"; };
        plugin = optionStr // { default = "org.kde.desktopcontainment"; };

        wallpaperPlugin = optionNullStr;
        wallpaperConfig = mkOption {
          type = types.attrs;
          default = {};
        };

        panels = mkOption {
          type = types.attrsOf panelType;
          default = {};
        };
      };
    }
  );

  parseConfig = prefix: foldlAttrs
    (acc: n: v:
    let
      keys = if n == "_" then prefix else prefix ++ [ n ];
    in
      acc ++ (
        foldlAttrs
          (acc: n: v:
            acc ++ [
              (mkItem keys n (toString v))
            ]
          )
          []
          v
      )
    )
    [];

  parseMonitor = v:
    let
      prefix = ["Containments" v.id];
      _mk = mkItem prefix;
    in
      [
        (_mk "activityId" v.activityId)
        (_mk "formfactor" v.formfactor)
        (_mk "immutability" v.immutability)
        (_mk "lastScreen" v.lastScreen)
        (_mk "location" v.location)
        (_mk "plugin" v.plugin)
      ] ++ optionals (v.wallpaperPlugin != null) (
        [(_mk "wallpaperplugin" v.wallpaperPlugin)] ++
        optionals
          (v.wallpaperConfig != {})
          (parseConfig (prefix ++ ["Wallpaper" v.wallpaperPlugin]) v.wallpaperConfig)
      );

  parsePanel = v:
    let
      prefix = ["Containments" v.id];
      _mk = mkItem prefix;

      appletOrder =
        if v.applets == [] then []
        else [(
          mkItem
            (prefix ++ ["General"])
            "AppletOrder"
            (concatStringsSep ";" (forEach v.applets (x: x.id)))
        )];
    in
      [
        (_mk "formfactor" v.formfactor)
        (_mk "immutability" v.immutability)
        (_mk "lastScreen" v.lastScreen)
        (_mk "location" v.location)
        (_mk "plugin" v.plugin)
      ] ++ parseConfig prefix v.extraConfig
        ++ appletOrder
        ++ foldl
        (acc: app:
        let
          prefix = ["Containments" v.id "Applets" app.id];
          _mk = mkItem prefix;
        in
          acc ++ [
            (_mk "immutability" "1")
            (_mk "plugin" app.plugin)
          ] ++ parseConfig (prefix ++ ["Configuration"]) app.config
        )
        []
        v.applets;
in {
  options.utils.plasma.monitors = mkOption {
    type = types.attrsOf monitorType;
    default = {};
  };

  config = mkIf (cfg != {}) {
    utils.kconfig.plasmashellrc.content =
      let
        items = foldlAttrs
          (acc: n: v:
            acc ++ (
              foldlAttrs
                (acc: n: v:
                  acc ++ (
                    parseConfig ["PlasmaViews" "Panel ${toString v.id}"] v.config
                  )
                )
                []
                v.panels
            )
          )
          []
          cfg;
      in
        convertItemsToKconfig items;

    utils.kconfig.appletsrc.content =
      let
        items = foldlAttrs
        (acc: n: v:
          acc ++ parseMonitor v ++
          foldlAttrs
            (acc: n: v:
              acc ++ parsePanel v
            )
            []
            v.panels
        )
        []
        cfg;
      in
        convertItemsToKconfig items;
  };
}
