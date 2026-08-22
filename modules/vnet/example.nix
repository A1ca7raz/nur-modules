{ pkgs, ... }:
{
  systemd.network.enable = true;
  networking.nftables.enable = true;

  systemd.network.networks.default = {
    matchConfig.Name = "eth0";
    DHCP = "yes";
  };

  services.caddy = {
    enable = true;
    virtualHosts.":80".extraConfig = ''
      handle_path /app1/* {
        reverse_proxy 169.254.100.2:8080
      }

      handle_path /app2/* {
        reverse_proxy 169.254.100.3:8080
      }

      handle_path /host-app/* {
        reverse_proxy 169.254.100.4:8080
      }
    '';
  };

  systemd.services = {
    app1 = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart =
        "${pkgs.python3}/bin/python -m http.server 8080 --bind 169.254.100.2";
    };

    app2 = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart =
        "${pkgs.python3}/bin/python -m http.server 8080 --bind 169.254.100.3";
    };

    host-app = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart =
        "${pkgs.python3}/bin/python -m http.server 8080 --bind 169.254.100.4";
    };
  };

  utils.vnet = {
    enable = true;

    # The uplink requests an IA_PD /64. No upstream RA is bridged into a
    # service namespace; vnet assigns routed /128 addresses instead.
    prefixDelegations.wan = {
      network = "default";
      hint = "::/64";
    };

    egress = {
      enable = true;
      uplink = "eth0";
      ipv4 = {
        pool = "169.254.200.0/24";
        masquerade = true;
      };
      ipv6.prefixDelegation = "wan";
      monitoring.enable = true;
    };

    gateways = {
      public.addresses = "198.18.0.1/24";
      internal.addresses = "198.18.1.1/24";
    };

    services = {
      proxy = {
        unit = "caddy";
        endpoint = "169.254.100.1";
        egress.enable = true;
        # Gateway interfaces without a default route are automatically treated
        # as inbound/reply-only, regardless of whether the service has egress.
        interfaces = {
          public = {
            gateway = "public";
            addresses = "198.18.0.2/24";
          };
          internal = {
            gateway = "internal";
            addresses = "198.18.1.2/24";
          };
        };
      };

      app1 = {
        egress.enable = true;
        interfaces.proxy = {
          addresses = "169.254.100.2";
          peer = "proxy";
        };
      };

      app2 = {
        egress = {
          enable = true;
          enableIPv6 = false;
        };
        interfaces.proxy = {
          addresses = "169.254.100.3";
          peer = "proxy";
        };
      };

      # This service stays in the host namespace. Its WebUI address is exposed
      # only through the shared host-to-proxy peer and is protected by nftables.
      host-app = {
        privateNetwork = false;
        interfaces.proxy = {
          addresses = "169.254.100.4";
          peer = "proxy";
        };
      };
    };
  };
}
