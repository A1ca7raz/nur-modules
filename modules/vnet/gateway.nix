{ config, lib, ... }:
let
  inherit (lib)
    filterAttrs
    mapAttrs'
    mkIf
    mkOption
    nameValuePair
    types
  ;

  cfg = config.utils.vnet;
  enabledGateways = filterAttrs (_: gateway: gateway.enable) cfg.gateways;
  inherit (import ./types.nix) gatewayModule;

  hash = value: builtins.hashString "sha256" value;
  shortHash = value: builtins.substring 0 11 (builtins.hashString "sha256" value);
  gatewayDevice = name: "gw${builtins.substring 0 13 (hash "gateway:${name}")}";
in
{
  options.utils.vnet.gateways = mkOption {
    type = with types; attrsOf (submodule gatewayModule);
    default = { };
    description = "Network gateways to which service interfaces can attach.";
  };

  config = mkIf (cfg.enable && enabledGateways != { }) {
    systemd.network.netdevs = mapAttrs' (
      name: gateway:
      nameValuePair "40-netns-gateway-${shortHash name}" {
        netdevConfig = {
          Name = gatewayDevice name;
          Kind = gateway.type;
        };
      }
    ) enabledGateways;

    systemd.network.networks = mapAttrs' (
      name: gateway:
      nameValuePair "40-netns-gateway-${shortHash name}" {
        matchConfig.Name = gatewayDevice name;
        linkConfig.RequiredForOnline = false;
        networkConfig = {
          Address = gateway.addresses;
          ConfigureWithoutCarrier = true;
        };
      }
    ) enabledGateways;
  };
}
