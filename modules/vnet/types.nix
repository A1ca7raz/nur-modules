{
  gatewayModule =
    { name, lib, ... }:
    let
      inherit (lib) mkOption types;
      vnetLib = import ./lib.nix { inherit lib; };
    in
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to create this gateway.";
        };

        type = mkOption {
          type = types.enum [ "bridge" ];
          default = "bridge";
          description = "Gateway implementation. Additional types such as VRF may be added later.";
        };

        addresses = mkOption {
          type = with types; coercedTo str (address: [ address ]) (listOf str);
          default = [ ];
          description = "Addresses assigned to the gateway device.";
        };

        device = mkOption {
          type = types.str;
          readOnly = true;
          description = "Generated Linux interface name for this gateway.";
        };
      };

      config.device = vnetLib.gatewayDevice name;
    };

  defaultRouteModule =
    { lib, ... }:
    let
      inherit (lib) mkOption types;
    in
    {
      options = {
        via = mkOption {
          type = with types; nullOr str;
          default = null;
          description = "Explicit default-route gateway address, or null to infer it from the gateway.";
        };

        metric = mkOption {
          type = with types; nullOr ints.unsigned;
          default = null;
          description = "Optional default-route metric.";
        };
      };
    };

  peerModule =
    { lib, ... }:
    let
      inherit (lib) mkOption types;
    in
    {
      options = {
        service = mkOption {
          type = types.str;
          description = "Peer service in utils.vnet.services.";
        };

        endpoint = mkOption {
          type = with types; nullOr str;
          default = null;
          description = ''
            Single peer endpoint address for this link. When null, the peer
            service's reusable endpoints are used.
          '';
        };
      };
    };

  interfaceModule =
    { lib, ... }:
    let
      inherit (lib) mkOption types;
      inherit (import ./types.nix) defaultRouteModule peerModule;
    in
    {
      options = {
        addresses = mkOption {
          type = with types; coercedTo str (address: [ address ]) (listOf str);
          default = [ ];
          description = "Addresses assigned to this service interface.";
        };

        gateway = mkOption {
          type = with types; nullOr str;
          default = null;
          description = "Gateway connected to this interface.";
        };

        peer = mkOption {
          type = with types; nullOr (coercedTo str (service: { inherit service; }) (submodule peerModule));
          default = null;
          description = "Peer service connected directly through a veth pair.";
        };

        defaultRoute = mkOption {
          type = with types;
            nullOr (
              coercedTo (enum [ true ]) (_: { }) (
                coercedTo str (via: { inherit via; }) (submodule defaultRouteModule)
              )
            );
          default = null;
          description = ''
            Optional default route through this gateway interface. Set true to
            infer the route from the gateway's addresses, or use an attribute
            set to also set metric. A string explicitly overrides via. Gateway
            default routes cannot be combined with host-managed egress.
          '';
        };
      };
    };

  serviceEgressModule =
    { lib, ... }:
    let
      inherit (lib) mkOption types;
    in
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Whether this service may initiate public IPv4 connections.";
        };

        enableIPv6 = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether public IPv6 is enabled when egress.enable is true. Disabled
            services are not assigned an address from the delegated prefix.
          '';
        };

        peerAddr = mkOption {
          type = types.str;
          readOnly = true;
          description = "Automatically allocated IPv4 address on the service side of the host transit peer.";
        };
      };
    };

  serviceModule =
    { name, lib, config, vnetEgressPeerAddr ? (_: ""), ... }:
    let
      inherit (lib) mkOption types;
      inherit (import ./types.nix) interfaceModule serviceEgressModule;
    in
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to configure networking for this service.";
        };

        unit = mkOption {
          type = types.str;
          default = name;
          description = "Attribute name under systemd.services. Defaults to the service name.";
        };

        privateNetwork = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether the service runs in a dedicated network namespace. When
            false, peer interfaces remain in the initial host namespace.
          '';
        };

        endpoint = mkOption {
          type = with types; nullOr str;
          default = null;
          description = "Reusable /32 or /128 endpoint owned by this service namespace.";
        };

        egress = mkOption {
          type = types.submodule serviceEgressModule;
          default = { };
          description = "Public egress policy and the computed host-transit peer address.";
        };

        interfaces = mkOption {
          type = with types; attrsOf (submodule interfaceModule);
          default = { };
          description = "Network interfaces attached to this service namespace.";
        };
      };

      config.egress.peerAddr =
        if config.enable && config.privateNetwork then vnetEgressPeerAddr name else "";
    };
}
