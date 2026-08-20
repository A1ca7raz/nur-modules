{
  gatewayModule =
    { lib, ... }:
    let
      inherit (lib) mkOption types;
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
      };
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
          description = ''
            Addresses assigned to this service interface. May be empty for an
            egress interface peered with the built-in host target; its IPv4
            address is then allocated from utils.vnet.egress.ipv4.pool.
          '';
        };

        addressId = mkOption {
          type = with types; nullOr ints.positive;
          default = null;
          description = ''
            Optional stable host ID for an automatically allocated egress
            address. The same ID is used for the IPv4 pool and delegated IPv6
            prefix. Null allocates the first available ID deterministically.
          '';
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

  serviceModule =
    { name, lib, ... }:
    let
      inherit (lib) mkOption types;
      inherit (import ./types.nix) interfaceModule;
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

        interfaces = mkOption {
          type = with types; attrsOf (submodule interfaceModule);
          default = { };
          description = "Network interfaces attached to this service namespace.";
        };
      };
    };
}
