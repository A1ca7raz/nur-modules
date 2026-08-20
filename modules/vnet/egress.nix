{ config
, lib
, pkgs
, utils
, ...
}:
let
  inherit (lib)
    concatMapStrings
    concatStringsSep
    filterAttrs
    mapAttrs'
    mapAttrsToList
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    nameValuePair
    optionalAttrs
    types
    unique
    ;

  cfg = config.utils.vnet;
  enabledServices = filterAttrs (_: service: service.enable) cfg.services;
  enabledPrefixDelegations = filterAttrs (_: delegation: delegation.enable) cfg.prefixDelegations;
  vnetLib = import ./lib.nix { inherit lib; };

  inherit (vnetLib)
    allocateEgressLinks
    parseIPv4Pool
    prefixDelegationDevice
    shortHash
    ;

  ip = "${pkgs.iproute2}/bin/ip";
  deviceUnit = interface:
    "sys-subsystem-net-devices-${utils.escapeSystemdPath interface}.device";

  egressLinks = allocateEgressLinks cfg enabledServices;
  ipv4Pool = parseIPv4Pool cfg.egress.ipv4.pool;
  hostAddress = ipv4Pool.addressAt 1;

  prefixDelegationName = cfg.egress.ipv6.prefixDelegation;
  hasPrefixDelegation =
    prefixDelegationName != null
    && builtins.hasAttr prefixDelegationName enabledPrefixDelegations;
  pdDevice =
    if hasPrefixDelegation then prefixDelegationDevice prefixDelegationName else "";

  counterName = link: family: direction:
    "vnet_${lib.replaceStrings [ "-" "." ] [ "_" "_" ] link.serviceName}_${family}_${direction}";
  counterStatement = link: family: direction:
    if cfg.egress.monitoring.enable then
      "counter name ${counterName link family direction}"
    else
      "";
  counterDefinitions = concatMapStrings
    (
      link:
      "${concatStringsSep "\n" (
      map
        (item: "counter ${counterName link item.family item.direction} { }")
        [
          { family = "ipv4"; direction = "tx"; }
          { family = "ipv4"; direction = "rx"; }
          { family = "ipv6"; direction = "tx"; }
          { family = "ipv6"; direction = "rx"; }
        ]
    )}\n"
    )
    egressLinks;

  forwardRules = concatMapStrings
    (
      link:
      let
        hostInterface = link.targetInterface;
      in
      ''
        # Only addresses routed back through this service's egress peer may
        # leave it; this prevents a namespace from spoofing a business address.
        iifname "${hostInterface}" fib saddr . iif oif missing drop

        meta nfproto ipv4 iifname "${hostInterface}" oifname "${cfg.egress.uplink}" ${counterStatement link "ipv4" "tx"} accept
        meta nfproto ipv6 iifname "${hostInterface}" oifname "${cfg.egress.uplink}" ${counterStatement link "ipv6" "tx"} accept

        meta nfproto ipv4 iifname "${cfg.egress.uplink}" oifname "${hostInterface}" ct state established,related ${counterStatement link "ipv4" "rx"} accept
        meta nfproto ipv6 iifname "${cfg.egress.uplink}" oifname "${hostInterface}" ct state established,related ${counterStatement link "ipv6" "rx"} accept

        iifname "${cfg.egress.uplink}" oifname "${hostInterface}" drop
        iifname "${hostInterface}" drop
      ''
    )
    egressLinks;

  inputInterfaces = concatStringsSep ", " (
    map (link: ''"${link.targetInterface}"'') egressLinks
  );

  calculateDelegatedAddress = pkgs.writeShellApplication {
    name = "vnet-delegated-address";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
            python -c '
      import ipaddress
      import sys

      network = ipaddress.IPv6Interface(sys.argv[1]).network
      address = network.network_address + int(sys.argv[2])
      if address not in network:
          raise SystemExit(f"address ID {sys.argv[2]} is outside {network}")
      print(address)
      ' "$1" "$2"
    '';
  };

  syncLink = link:
    let
      stateName = shortHash "egress-state:${link.key}";
      namespace = link.serviceName;
      interface = link.interfaceName;
      hostInterface = link.targetInterface;
    in
    ''
      state_file="$state_dir/${stateName}"
      old_address=""
      if [[ -r "$state_file" ]]; then
        old_address="$(<"$state_file")"
      fi

      link_ready=false
      if [[ -e "/run/netns/${namespace}" ]] \
        && ${ip} link show dev "${hostInterface}" >/dev/null 2>&1 \
        && ${ip} -n "${namespace}" link show dev "${interface}" >/dev/null 2>&1; then
        link_ready=true
      fi

      if [[ -z "$pd_cidr" || "$link_ready" != true ]]; then
        if [[ -n "$old_address" ]]; then
          if [[ -e "/run/netns/${namespace}" ]]; then
            ${ip} -n "${namespace}" -6 address del "$old_address/128" dev "${interface}" 2>/dev/null || true
          fi
          ${ip} -6 route del "$old_address/128" dev "${hostInterface}" 2>/dev/null || true
          rm -f "$state_file"
        fi
      else
        new_address="$(${lib.getExe calculateDelegatedAddress} "$pd_cidr" "${toString link.addressId}")"

        if [[ -n "$old_address" && "$old_address" != "$new_address" ]]; then
          ${ip} -n "${namespace}" -6 address del "$old_address/128" dev "${interface}" 2>/dev/null || true
          ${ip} -6 route del "$old_address/128" dev "${hostInterface}" 2>/dev/null || true
        fi

        ${ip} -n "${namespace}" -6 address replace "$new_address/128" dev "${interface}" nodad
        ${ip} -6 route replace "$new_address/128" dev "${hostInterface}"
        printf '%s\n' "$new_address" > "$state_file"
      fi
    '';

  syncScript = pkgs.writeShellApplication {
    name = "vnet-egress-sync";
    runtimeInputs = [ pkgs.gawk pkgs.iproute2 ];
    text = ''
      state_dir=/run/vnet-egress
      mkdir -p "$state_dir"

      pd_cidr="$(${ip} -6 -o address show dev "${pdDevice}" scope global 2>/dev/null \
        | awk 'NR == 1 { print $4 }' || true)"

      ${concatMapStrings syncLink egressLinks}
    '';
  };

  prefixWatcher = pkgs.writeShellApplication {
    name = "vnet-egress-prefix-watch";
    runtimeInputs = [ pkgs.iproute2 ];
    text = ''
      ${lib.getExe syncScript}
      ${ip} -6 monitor address dev "${pdDevice}" | while read -r _; do
        ${lib.getExe syncScript}
      done
    '';
  };

  prefixDelegationNetdevs = mapAttrs'
    (
      name: _:
        nameValuePair "40-vnet-prefix-delegation-${shortHash name}" {
          netdevConfig = {
            Name = prefixDelegationDevice name;
            Kind = "dummy";
          };
        }
    )
    enabledPrefixDelegations;

  prefixDelegationNetworks = mapAttrs'
    (
      name: delegation:
        nameValuePair "40-vnet-prefix-delegation-${shortHash name}" {
          matchConfig.Name = prefixDelegationDevice name;
          linkConfig.RequiredForOnline = false;
          networkConfig = {
            ConfigureWithoutCarrier = true;
            DHCPPrefixDelegation = true;
            IPv6AcceptRA = false;
            IPv6SendRA = false;
          };
          dhcpPrefixDelegationConfig = {
            UplinkInterface = cfg.egress.uplink;
            SubnetId = toString delegation.subnetId;
            Announce = false;
            Assign = true;
            Token = "::1";
            ManageTemporaryAddress = false;
          };
        }
    )
    enabledPrefixDelegations;

  upstreamNetworks = mkMerge (
    mapAttrsToList
      (
        _: delegation:
          {
            ${delegation.network} = {
              networkConfig.IPv6AcceptRA = true;
              dhcpV6Config = {
                PrefixDelegationHint = delegation.hint;
                UseAddress = delegation.useAddress;
                UseDelegatedPrefix = true;
                WithoutRA = "solicit";
              };
              ipv6AcceptRAConfig.DHCPv6Client = "always";
            };
          }
      )
      enabledPrefixDelegations
  );

  egressLinkDropins = builtins.listToAttrs (
    map
      (
        link:
        nameValuePair "netns-link-${shortHash "peer-link:${link.key}"}" {
          requires = [ "vnet-egress-host.service" ];
          after = [ "vnet-egress-host.service" ];
          serviceConfig.ExecStartPost = lib.optional hasPrefixDelegation (lib.getExe syncScript);
        }
      )
      egressLinks
  );

  egressServiceNames = unique (map (link: link.serviceName) egressLinks);
  egressDnsDropins = mkMerge (
    map
      (
        serviceName:
        let
          service = enabledServices.${serviceName};
          writeResolvConf = pkgs.writeShellScript "vnet-resolv-${serviceName}" ''
            printf 'nameserver ${hostAddress}\n' > /etc/netns/${serviceName}/resolv.conf
          '';
        in
        {
          "netns@${serviceName}" = {
            overrideStrategy = "asDropin";
            serviceConfig.ExecStartPost = [ writeResolvConf ];
          };
          ${service.unit}.serviceConfig.BindReadOnlyPaths = [
            "/etc/netns/${serviceName}/resolv.conf:/etc/resolv.conf"
          ];
        }
      )
      egressServiceNames
  );

  allocatedIds = map (link: link.addressId) egressLinks;
in
{
  options.utils.vnet = {
    prefixDelegations = mkOption {
      default = { };
      description = "DHCPv6 prefixes acquired by systemd-networkd for vnet use.";
      type = types.attrsOf (types.submodule ({ ... }: {
        options = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Whether to request and consume this prefix delegation.";
          };
          network = mkOption {
            type = types.str;
            description = "Attribute name under systemd.network.networks for the uplink.";
          };
          hint = mkOption {
            type = types.str;
            default = "::/64";
            description = "DHCPv6 prefix delegation hint.";
          };
          subnetId = mkOption {
            type = types.ints.unsigned;
            default = 0;
            description = "Subnet ID selected from the delegated prefix.";
          };
          useAddress = mkOption {
            type = types.bool;
            default = false;
            description = "Whether the uplink also accepts a DHCPv6 IA_NA address.";
          };
        };
      }));
    };

    egress = {
      enable = mkEnableOption "host-routed vnet egress";

      uplink = mkOption {
        type = types.str;
        description = "Host interface used for outbound traffic.";
      };

      ipv4 = {
        pool = mkOption {
          type = types.str;
          default = "169.254.200.0/24";
          description = "IPv4 allocation pool for point-to-point egress links.";
        };
        masquerade = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to masquerade IPv4 egress on the uplink.";
        };
      };

      ipv6 = {
        prefixDelegation = mkOption {
          type = with types; nullOr str;
          default = null;
          description = "Name under utils.vnet.prefixDelegations used for IPv6 egress.";
        };
        masquerade = mkOption {
          type = types.bool;
          default = false;
          readOnly = true;
          description = "IPv6 masquerading is intentionally unsupported.";
        };
      };

      monitoring.enable = mkEnableOption "per-service nftables egress counters";
    };
  };

  config = mkIf (cfg.enable && cfg.egress.enable) {
    assertions = [
      {
        assertion = config.networking.nftables.enable;
        message = "utils.vnet.egress requires networking.nftables.enable.";
      }
      {
        assertion = prefixDelegationName == null || hasPrefixDelegation;
        message = "utils.vnet.egress.ipv6.prefixDelegation refers to a missing or disabled prefix delegation.";
      }
      {
        assertion = builtins.all (link: link.service.privateNetwork) egressLinks;
        message = "utils.vnet egress links must originate in a private service network namespace.";
      }
      {
        assertion = builtins.all (link: link.interface.addresses == [ ]) egressLinks;
        message = "utils.vnet egress interface addresses are allocated automatically and must be empty.";
      }
      {
        assertion = builtins.length allocatedIds == builtins.length (unique allocatedIds);
        message = "utils.vnet egress addressId values must be unique.";
      }
      {
        assertion = builtins.all (addressId: addressId > 1 && addressId <= ipv4Pool.capacity) allocatedIds;
        message = "utils.vnet egress addressId values must fit the IPv4 pool and may not use host ID 1.";
      }
      {
        assertion = builtins.all
          (
            delegation: builtins.hasAttr delegation.network config.systemd.network.networks
          )
          (builtins.attrValues enabledPrefixDelegations);
        message = "utils.vnet.prefixDelegations.*.network must name an existing systemd network.";
      }
    ];

    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = lib.mkDefault 1;
      "net.ipv6.conf.all.forwarding" = lib.mkDefault 1;
      "net.ipv6.conf.default.forwarding" = lib.mkDefault 1;
    };

    systemd.network = {
      netdevs = prefixDelegationNetdevs;
      networks = mkMerge [ upstreamNetworks prefixDelegationNetworks ];
    };

    systemd.services = mkMerge [
      {
        vnet-egress-host = {
          description = "Configure the shared vnet host egress endpoint";
          wantedBy = [ "multi-user.target" ];
          after = [ "systemd-networkd.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${ip} address replace ${hostAddress}/32 dev lo";
            ExecStop = "-${ip} address del ${hostAddress}/32 dev lo";
          };
        };
      }
      egressLinkDropins
      egressDnsDropins
      (optionalAttrs hasPrefixDelegation {
        vnet-egress-prefix-watch = {
          description = "Synchronize delegated IPv6 addresses into vnet namespaces";
          wantedBy = [ "multi-user.target" ];
          wants = [ (deviceUnit pdDevice) ];
          after = [ "systemd-networkd.service" (deviceUnit pdDevice) ];
          serviceConfig = {
            Type = "simple";
            ExecStart = lib.getExe prefixWatcher;
            Restart = "always";
            RestartSec = 1;
          };
        };
      })
    ];

    networking.nftables.tables.vnet-egress = {
      family = "inet";
      content = ''
        ${counterDefinitions}

        chain input {
          type filter hook input priority -20; policy accept;

          ${lib.optionalString (egressLinks != [ ]) ''
            iifname { ${inputInterfaces} } ip daddr ${hostAddress} accept
          ''}
          ip daddr ${hostAddress} drop
        }

        chain forward {
          type filter hook forward priority -20; policy accept;

          ${forwardRules}
        }

        ${lib.optionalString cfg.egress.ipv4.masquerade ''
          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;

            ip saddr ${ipv4Pool.network} oifname "${cfg.egress.uplink}" masquerade
          }
        ''}
      '';
    };

    services.resolved.settings.Resolve.DNSStubListenerExtra = mkIf
      config.services.resolved.enable
      [ hostAddress ];
  };
}
