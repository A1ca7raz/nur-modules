{ config, lib, ... }:
let
  inherit (lib)
    filterAttrs
    mapAttrs'
    mkIf
    mkOption
    nameValuePair
    types
    unique
    ;

  cfg = config.utils.vnet;
  enabledGateways = filterAttrs (_: gateway: gateway.enable) cfg.gateways;
  inherit (import ./types.nix) gatewayModule;

  vnetLib = import ./lib.nix { inherit lib; };
  inherit (vnetLib) sanitizeName;
  gatewayDevices = map (gateway: gateway.device) (builtins.attrValues enabledGateways);
in
{
  options.utils.vnet.gateways = mkOption {
    type = with types; attrsOf (submodule gatewayModule);
    default = { };
    description = "Network gateways to which service interfaces can attach.";
  };

  config = mkIf (cfg.enable && enabledGateways != { }) {
    assertions = [
      {
        assertion = builtins.length gatewayDevices == builtins.length (unique gatewayDevices);
        message = "utils.vnet gateway names must remain unique after truncation to Linux interface names.";
      }
    ];

    systemd.network.netdevs = mapAttrs'
      (
        name: gateway:
          nameValuePair "40-vnet-bridge-${sanitizeName name}" {
            netdevConfig = {
              Name = gateway.device;
              Kind = gateway.type;
            };
          }
      )
      enabledGateways;

    systemd.network.networks = mapAttrs'
      (
        name: gateway:
          nameValuePair "40-vnet-bridge-${sanitizeName name}" {
            matchConfig.Name = gateway.device;
            linkConfig.RequiredForOnline = false;
            networkConfig = {
              Address = gateway.addresses;
              ConfigureWithoutCarrier = true;
            };
          }
      )
      enabledGateways;
  };
}
