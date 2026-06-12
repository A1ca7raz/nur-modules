{ pkgs, ... }:
{
  # utils.vnet only checks this dependency; it never enables networkd itself.
  systemd.network.enable = true;

  services.caddy = {
    enable = true;
    virtualHosts.":80".extraConfig = ''
      handle_path /app1/* {
        reverse_proxy 10.255.0.2:8080
      }

      handle_path /app2/* {
        reverse_proxy 10.255.0.3:8080
      }
    '';
  };

  systemd.services = {
    "direct-app" = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
    };

    app1 = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python -m http.server 8080 --bind 10.255.0.2";
        Restart = "on-failure";
      };
    };

    app2 = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python -m http.server 8080 --bind 10.255.0.3";
        Restart = "on-failure";
      };
    };
  };

  utils.vnet = {
    enable = true;

    gateways = {
      public.addresses = "10.10.0.1/24";
      internal.addresses = "10.20.0.1/24";
    };

    services = {
      # One service can connect to multiple gateways.
      "direct-app".interfaces = {
        public = {
          gateway = "public";
          addresses = "10.10.0.10/24";

          # Infer 10.10.0.1 from gateways.public.addresses.
          defaultRoute = true;
        };

        internal = {
          gateway = "internal";
          addresses = "10.20.0.10/24";
        };
      };

      # Caddy owns one reusable /32 endpoint and also connects to a gateway.
      caddy = {
        endpoint = "10.255.0.1";
        interfaces.public = {
          gateway = "public";
          addresses = "10.10.0.2/24";
          defaultRoute = true;
        };
      };

      # Both applications reuse caddy.endpoint, so peer.endpoint is omitted.
      app1.interfaces.proxy = {
        addresses = "10.255.0.2";
        peer = "caddy";
      };

      app2.interfaces.proxy = {
        addresses = "10.255.0.3";
        peer = "caddy";
      };
    };
  };
}
