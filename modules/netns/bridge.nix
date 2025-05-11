{ pkgs, config, lib, ... }:
let
  inherit (lib)
    mkOption
    types
    mkIf
    foldlAttrs
    foldl
  ;

  cfg = config.utils.netns;

  inherit (import ./types.nix) bridgeModule;

  ip = "${pkgs.iproute2}/bin/ip";
in {
  options.utils.netns.bridge = mkOption {
    type = with types; attrsOf (submodule bridgeModule);
    default = {};
    description = "Attribute set of secrets to enable";
  };

  config = mkIf (cfg.enable && cfg.bridge != {}) {
    systemd.services = {
      "netns-bridge@" = {
        description = "Named network namespace bridge %I";

        unitConfig.StopWhenUnneeded = true;

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = [
            "${ip} link add vnet-%i type bridge"
            "${ip} link set dev vnet-%i up"
          ];
          ExecStop = "${ip} link del vnet-%i";
        };
      };
    } // (foldlAttrs (acc: name: val:
      {
        "netns-bridge@${name}" = {
          overrideStrategy = "asDropin";
          path = [ pkgs.iproute2 ];

          serviceConfig.ExecStartPost = foldl (acc: ip_:
            [
              "${ip} addr add ${ip_} dev vnet-${name}"
            ] ++ acc
          ) [] val.ipAddrs;
        };
      } // acc
    ) {} cfg.bridge);
  };
}
