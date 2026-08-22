{ config
, lib
, pkgs
, utils
, ...
}:
let
  inherit (lib)
    all
    concatMap
    concatStringsSep
    filter
    filterAttrs
    groupBy
    hasInfix
    hasSuffix
    mapAttrs'
    mapAttrsToList
    mkIf
    mkMerge
    mkOption
    nameValuePair
    optional
    optionalAttrs
    optionalString
    optionals
    splitString
    types
    unique
    ;

  cfg = config.utils.vnet;
  enabledServices = filterAttrs (_: service: service.enable) cfg.services;
  enabledGateways = filterAttrs (_: gateway: gateway.enable) cfg.gateways;
  inherit (import ./types.nix) serviceModule;
  vnetLib = import ./lib.nix { inherit lib; };
  inherit (vnetLib)
    allocateEgressLinks
    egressLinkServiceName
    gatewayLinkServiceName
    ipv4Network
    kernelName
    macAddress
    nftIdentifier
    peerLinkNames
    peerLinkServiceName
    rawLinks
    shortHash
    ;

  ip = "${pkgs.iproute2}/bin/ip";
  waitOnline = "${config.systemd.package}/lib/systemd/systemd-networkd-wait-online";

  isIPv6 = address: hasInfix ":" address;
  addressIP = address: builtins.head (splitString "/" address);
  normalizeAddress = address:
    if hasInfix "/" address then
      address
    else
      "${address}/${if isIPv6 address then "128" else "32"}";
  hostPrefix = address: "${addressIP address}/${if isIPv6 address then "128" else "32"}";
  familyFlag = address: if isIPv6 address then "-6" else "-4";
  family = address: if isIPv6 address then "ipv6" else "ipv4";
  isHostPrefix = address:
    let
      normalized = normalizeAddress address;
    in
    if isIPv6 normalized then hasSuffix "/128" normalized else hasSuffix "/32" normalized;

  ipCommand = args: "${ip} ${utils.escapeSystemdExecArgs args}";
  ignored = command: "-${command}";
  deviceUnit = interface: "sys-subsystem-net-devices-${utils.escapeSystemdPath interface}.device";
  netnsUnit = service: "netns@${service}.service";

  declaredRawLinks = rawLinks enabledServices;
  allocatedEgressLinks = allocateEgressLinks cfg cfg.services;
  allRawLinks = declaredRawLinks ++ allocatedEgressLinks;
  egressServiceNames = unique (builtins.map (link: link.serviceName) allocatedEgressLinks);
  egressLinksByKey = builtins.listToAttrs (
    builtins.map (link: nameValuePair link.key link) allocatedEgressLinks
  );
  isEgressLink = link: builtins.hasAttr link.key egressLinksByKey;
  effectiveAddresses = link:
    if isEgressLink link then [ egressLinksByKey.${link.key}.ipv4Address ] else link.interface.addresses;

  validGatewayLinks = filter
    (
      link: link.interface.gateway != null && link.interface.peer == null
    )
    allRawLinks;
  validPeerLinks = filter
    (
      link: link.interface.peer != null && link.interface.gateway == null
    )
    allRawLinks;

  effectivePeerEndpoints = link:
    if link.interface.peer.endpoint != null then
      [ link.interface.peer.endpoint ]
    else if link.interface.peer.service == "host" && isEgressLink link then
      [ "${(vnetLib.parseIPv4Pool cfg.egress.ipv4.pool).addressAt 1}/32" ]
    else if
      builtins.hasAttr link.interface.peer.service enabledServices
      && enabledServices.${link.interface.peer.service}.endpoint != null
    then
      [ enabledServices.${link.interface.peer.service}.endpoint ]
    else
      [ ];

  gatewayLinks = builtins.genList
    (
      index:
      let
        link = builtins.elemAt validGatewayLinks index;
      in
      link
      // {
        type = "gateway";
        setupService = gatewayLinkServiceName link.serviceName link.interfaceName;
        hostInterface = kernelName "vg-" (
          if lib.hasPrefix "${link.serviceName}-" link.interfaceName then
            link.interfaceName
          else
            "${link.serviceName}-${link.interfaceName}"
        );
        serviceInterface = kernelName "vgs${toString index}-" link.key;
        hostMac = macAddress "gateway-host:${link.key}";
        serviceMac = macAddress "gateway-service:${link.key}";
        gateway = link.interface.gateway;
        replyRouteTable = 10000 + index;
        replyRoutePriority = 10000 + index;
      }
    )
    (builtins.length validGatewayLinks);

  privatePeerGroups = builtins.map
    (link: {
      key = link.key;
      members = [ link ];
    })
    (filter (link: link.service.privateNetwork) validPeerLinks);
  hostPeerGroups = mapAttrsToList
    (
      groupKey: members: {
        key = "host-peer:${groupKey}";
        macKey =
          let
            link = builtins.head members;
          in
          "host-peer:${shortHash (
            "${link.interface.peer.service}:${builtins.toJSON (effectivePeerEndpoints link)}"
          )}";
        inherit members;
      }
    )
    (groupBy
      (
        link:
        builtins.toJSON {
          targetService = link.interface.peer.service;
          endpoints = effectivePeerEndpoints link;
        }
      )
      (filter (link: !link.service.privateNetwork) validPeerLinks));

  peerLinks = builtins.map
    (
      group:
      let
        link = builtins.head group.members;
        names =
          if isEgressLink link then
            {
              inherit (link)
                sourceInterface
                targetInterface
                sourceMac
                targetMac
                ;
            }
          else
            peerLinkNames link.serviceName (group.macKey or group.key);
      in
      link
      // names
      // {
        key = group.key;
        type = "peer";
        setupService =
          if isEgressLink link then
            egressLinkServiceName link.serviceName
          else
            peerLinkServiceName group.members;
        targetService = link.interface.peer.service;
        endpoints = effectivePeerEndpoints link;
        sourceAddresses = unique (
          concatMap
            (
              member: builtins.map normalizeAddress (effectiveAddresses member)
            )
            group.members
        );
        targetIsHost = link.interface.peer.service == "host";
        egress = isEgressLink link;
        egressIPv6 = isEgressLink link && egressLinksByKey.${link.key}.ipv6;
        inherit (group) members;
      }
    )
    (privatePeerGroups ++ hostPeerGroups);

  allLinks = gatewayLinks ++ peerLinks;

  businessIPv4Networks = unique (
    concatMap
      (
        gateway:
        builtins.map ipv4Network (
          filter (address: !isIPv6 address) gateway.addresses
        )
      )
      (builtins.attrValues enabledGateways)
  );

  replyRoutingEnabled = link:
    link.interface.gateway != null
    && link.interface.defaultRoute == null;

  firstAddress = addressFamily: addresses:
    let
      matching = filter (address: family address == addressFamily) addresses;
    in
    if matching == [ ] then
      (if addressFamily == "ipv6" then "::" else "0.0.0.0")
    else
      addressIP (builtins.head matching);

  serviceNamespace = serviceName:
    if enabledServices.${serviceName}.privateNetwork then serviceName else null;
  namespaceArgs = namespace:
    if namespace == null then [ ] else [ "-n" namespace ];
  namespacedIpCommand = namespace: args:
    ipCommand (namespaceArgs namespace ++ args);

  moveAndRename = namespace: temporary: final:
    [ (ipCommand [ "link" "set" "dev" temporary "netns" namespace ]) ]
    ++ optional
      (temporary != final)
      (ipCommand [ "-n" namespace "link" "set" "dev" temporary "name" final ]);

  returnToInitialNamespace = namespace: temporary: final:
    optional
      (temporary != final)
      (ignored (ipCommand [ "-n" namespace "link" "set" "dev" final "name" temporary ]))
    ++ [
      (ignored (ipCommand [ "-n" namespace "link" "set" "dev" temporary "netns" "1" ]))
    ];

  addressCommands = namespace: interface: addresses:
    builtins.map (namespacedAddressCommand namespace interface) addresses;

  namespacedAddressCommand = namespace: interface: address:
    namespacedIpCommand namespace (
      [ "address" "replace" (normalizeAddress address) "dev" interface ]
      ++ optionals (isIPv6 address) [ "nodad" ]
    );

  defaultRouteAddresses = link:
    let
      defaultRoute = link.interface.defaultRoute;
      gatewayExists = builtins.hasAttr link.gateway enabledGateways;
      sourceFamilies = unique (builtins.map family link.interface.addresses);
    in
    if defaultRoute == null then
      [ ]
    else if defaultRoute.via != null then
      [ defaultRoute.via ]
    else if gatewayExists then
      filter
        (
          address: builtins.elem (family address) sourceFamilies
        )
        enabledGateways.${link.gateway}.addresses
    else
      [ ];

  gatewayStartCommands = link:
    let
      namespace = link.serviceName;
      interface = link.interfaceName;
      defaultRoute = link.interface.defaultRoute;
      routeCommands = concatMap
        (
          gatewayAddress:
          let
            via = addressIP gatewayAddress;
            flag = familyFlag via;
          in
          [
            (ipCommand [
              "-n"
              namespace
              flag
              "route"
              "replace"
              (hostPrefix via)
              "dev"
              interface
              "scope"
              "link"
            ])
            (ipCommand (
              [
                "-n"
                namespace
                flag
                "route"
                "replace"
                "default"
                "via"
                via
                "dev"
                interface
              ]
              ++ optionals (defaultRoute.metric != null) [ "metric" (toString defaultRoute.metric) ]
            ))
          ]
        )
        (defaultRouteAddresses link);
    in
    moveAndRename namespace link.serviceInterface interface
    ++ addressCommands namespace interface link.interface.addresses
    ++ [ (ipCommand [ "-n" namespace "link" "set" "dev" interface "up" ]) ]
    ++ routeCommands
    ++ replyRoutingStartCommands link
    ++ replyRoutingFirewallStartCommands link
    ++ [
      (
        "${waitOnline} ${utils.escapeSystemdExecArgs [
        "--interface=${link.hostInterface}:enslaved"
        "--timeout=30"
      ]}"
      )
    ];

  replyRoutingStartCommands = link:
    optionals (replyRoutingEnabled link) (
      concatMap
        (
          sourceFamily:
          let
            matchingGateways = filter
              (gatewayAddress: family gatewayAddress == sourceFamily)
              enabledGateways.${link.gateway}.addresses;
          in
          if matchingGateways == [ ] then
            [ ]
          else
            let
              gatewayAddress = addressIP (builtins.head matchingGateways);
              flag = if sourceFamily == "ipv6" then "-6" else "-4";
              table = toString link.replyRouteTable;
              priority = toString link.replyRoutePriority;
              bootstrapMetric = toString (40000 + link.replyRouteTable);
            in
            [
              (ipCommand [
                "-n"
                link.serviceName
                flag
                "route"
                "replace"
                (hostPrefix gatewayAddress)
                "dev"
                link.interfaceName
                "scope"
                "link"
                "table"
                table
              ])
              (ipCommand [
                "-n"
                link.serviceName
                flag
                "route"
                "replace"
                "default"
                "via"
                gatewayAddress
                "dev"
                link.interfaceName
                "table"
                table
              ])
              (ipCommand [
                "-n"
                link.serviceName
                flag
                "route"
                "replace"
                "default"
                "via"
                gatewayAddress
                "dev"
                link.interfaceName
                "metric"
                bootstrapMetric
              ])
              (ignored (ipCommand [
                "-n"
                link.serviceName
                flag
                "rule"
                "delete"
                "priority"
                priority
                "fwmark"
                table
                "table"
                table
              ]))
              (ipCommand [
                "-n"
                link.serviceName
                flag
                "rule"
                "add"
                "priority"
                priority
                "fwmark"
                table
                "table"
                table
              ])
            ]
        )
        (unique (builtins.map family link.interface.addresses))
    );

  replyRoutingStopCommands = link:
    optionals (replyRoutingEnabled link) (
      concatMap
        (
          sourceFamily:
          let
            matchingGateways = filter
              (gatewayAddress: family gatewayAddress == sourceFamily)
              enabledGateways.${link.gateway}.addresses;
          in
          if matchingGateways == [ ] then
            [ ]
          else
            let
              flag = if sourceFamily == "ipv6" then "-6" else "-4";
              table = toString link.replyRouteTable;
              priority = toString link.replyRoutePriority;
              bootstrapMetric = toString (40000 + link.replyRouteTable);
              gatewayAddress = addressIP (builtins.head matchingGateways);
            in
            [
              (ignored (ipCommand [
                "-n"
                link.serviceName
                flag
                "rule"
                "delete"
                "priority"
                priority
                "fwmark"
                table
                "table"
                table
              ]))
              (ignored (ipCommand [
                "-n"
                link.serviceName
                flag
                "route"
                "delete"
                "default"
                "via"
                gatewayAddress
                "dev"
                link.interfaceName
                "metric"
                bootstrapMetric
              ]))
              (ignored (ipCommand [
                "-n"
                link.serviceName
                flag
                "route"
                "flush"
                "table"
                table
              ]))
            ]
        )
        (unique (builtins.map family link.interface.addresses))
    );

  replyRoutingTableName = link:
    "vnet_reply_${nftIdentifier (vnetLib.linkName link.serviceName link.interfaceName)}";
  replyRoutingFirewall = link:
    let
      mark = toString link.replyRouteTable;
      tableName = replyRoutingTableName link;
      ipv4Addresses = builtins.map addressIP (
        filter (address: family address == "ipv4") link.interface.addresses
      );
      ipv6Addresses = builtins.map addressIP (
        filter (address: family address == "ipv6") link.interface.addresses
      );
    in
    pkgs.writeText "${tableName}.nft" ''
      table inet ${tableName} {
        chain prerouting {
          type filter hook prerouting priority mangle; policy accept;

          iifname "${link.interfaceName}" ct direction original ct mark set ${mark}
        }

        chain output_route {
          type route hook output priority mangle; policy accept;

          ct mark ${mark} meta mark set ct mark
        }

        chain output_filter {
          type filter hook output priority filter; policy accept;

          oifname "${link.interfaceName}" meta nfproto ipv6 icmpv6 type {
            nd-neighbor-solicit,
            nd-neighbor-advert
          } accept
          oifname "${link.interfaceName}" ct mark != ${mark} drop
          ${optionalString (ipv4Addresses != [ ]) ''
            oifname != "lo" ip saddr { ${concatStringsSep ", " ipv4Addresses} } ct mark != ${mark} drop
          ''}
          ${optionalString (ipv6Addresses != [ ]) ''
            oifname != "lo" ip6 saddr { ${concatStringsSep ", " ipv6Addresses} } ct mark != ${mark} drop
          ''}
        }
      }
    '';
  replyRoutingFirewallStartCommands = link:
    optionals (replyRoutingEnabled link) [
      (ignored (ipCommand [
        "netns"
        "exec"
        link.serviceName
        "${pkgs.nftables}/bin/nft"
        "delete"
        "table"
        "inet"
        (replyRoutingTableName link)
      ]))
      (ipCommand [
        "netns"
        "exec"
        link.serviceName
        "${pkgs.nftables}/bin/nft"
        "-f"
        (toString (replyRoutingFirewall link))
      ])
    ];
  replyRoutingFirewallStopCommands = link:
    optionals (replyRoutingEnabled link) [
      (ignored (ipCommand [
        "netns"
        "exec"
        link.serviceName
        "${pkgs.nftables}/bin/nft"
        "delete"
        "table"
        "inet"
        (replyRoutingTableName link)
      ]))
    ];

  peerStartCommands = link:
    let
      sourceNamespace = serviceNamespace link.serviceName;
      targetNamespace =
        if link.targetIsHost then null else serviceNamespace link.targetService;
      sourceFinal =
        if sourceNamespace == null then link.sourceInterface else link.interfaceName;
      targetFinal = link.targetInterface;
      sourceAddresses = link.sourceAddresses;
      targetEndpoints = builtins.map normalizeAddress link.endpoints;
      hostLinkLocal = "fe80::${lib.network.ipv6.mkEUI64Suffix link.targetMac}";

      sourceMove =
        if sourceNamespace == null then [ ]
        else moveAndRename sourceNamespace link.sourceInterface sourceFinal;
      targetMove =
        if targetNamespace == null then [ ]
        else moveAndRename targetNamespace link.targetInterface targetFinal;

      sourceRoutes = builtins.map
        (
          endpoint:
          namespacedIpCommand sourceNamespace [
            (familyFlag endpoint)
            "route"
            "replace"
            (hostPrefix endpoint)
            "dev"
            sourceFinal
            "scope"
            "link"
            "src"
            (firstAddress (family endpoint) sourceAddresses)
          ]
        )
        targetEndpoints;
      sourceNeighbors = builtins.map
        (
          endpoint:
          namespacedIpCommand sourceNamespace [
            (familyFlag endpoint)
            "neigh"
            "replace"
            (addressIP endpoint)
            "lladdr"
            link.targetMac
            "nud"
            "permanent"
            "dev"
            sourceFinal
          ]
        )
        targetEndpoints;
      targetRoutes = builtins.map
        (
          address:
          namespacedIpCommand targetNamespace [
            (familyFlag address)
            "route"
            "replace"
            (hostPrefix address)
            "dev"
            targetFinal
            "scope"
            "link"
            "src"
            (firstAddress (family address) targetEndpoints)
          ]
        )
        sourceAddresses;
      targetNeighbors = builtins.map
        (
          address:
          namespacedIpCommand targetNamespace [
            (familyFlag address)
            "neigh"
            "replace"
            (addressIP address)
            "lladdr"
            link.sourceMac
            "nud"
            "permanent"
            "dev"
            targetFinal
          ]
        )
        sourceAddresses;

      egressIPv6Commands = optionals link.egressIPv6 [
        (namespacedAddressCommand targetNamespace targetFinal "${hostLinkLocal}/64")
        (namespacedIpCommand sourceNamespace [
          "-6"
          "route"
          "replace"
          "${hostLinkLocal}/128"
          "dev"
          sourceFinal
          "scope"
          "link"
        ])
        (namespacedIpCommand sourceNamespace [
          "-6"
          "neigh"
          "replace"
          hostLinkLocal
          "lladdr"
          link.targetMac
          "nud"
          "permanent"
          "dev"
          sourceFinal
        ])
        (namespacedIpCommand sourceNamespace (
          [
            "-6"
            "route"
            "replace"
            "default"
            "via"
            hostLinkLocal
            "dev"
            sourceFinal
          ]
          ++ optionals (link.interface.defaultRoute.metric != null) [
            "metric"
            (toString link.interface.defaultRoute.metric)
          ]
        ))
      ];

      peerDefaultRoutes = optionals (link.interface.defaultRoute != null) (
        concatMap
          (
            endpoint:
            optional (family endpoint == "ipv4") (
              namespacedIpCommand sourceNamespace (
                [
                  "-4"
                  "route"
                  "replace"
                  "default"
                  "via"
                  (addressIP endpoint)
                  "dev"
                  sourceFinal
                ]
                ++ optionals (link.interface.defaultRoute.metric != null) [
                  "metric"
                  (toString link.interface.defaultRoute.metric)
                ]
              )
            )
          )
          targetEndpoints
      );

      businessRouteTable = "9000";
      businessRoutePriority = "9000";
      businessRouteCommands = optionals (link.egress && businessIPv4Networks != [ ]) (
        [
          (namespacedIpCommand sourceNamespace [
            "-4"
            "route"
            "replace"
            (hostPrefix (builtins.head targetEndpoints))
            "dev"
            sourceFinal
            "scope"
            "link"
            "src"
            (firstAddress "ipv4" sourceAddresses)
            "table"
            businessRouteTable
          ])
        ]
        ++ concatMap
          (
            network: [
              (namespacedIpCommand sourceNamespace [
                "-4"
                "route"
                "replace"
                network
                "via"
                (addressIP (builtins.head targetEndpoints))
                "dev"
                sourceFinal
                "src"
                (firstAddress "ipv4" sourceAddresses)
                "table"
                businessRouteTable
              ])
              (ignored (namespacedIpCommand sourceNamespace [
                "-4"
                "rule"
                "delete"
                "priority"
                businessRoutePriority
                "to"
                network
                "table"
                businessRouteTable
              ]))
              (namespacedIpCommand sourceNamespace [
                "-4"
                "rule"
                "add"
                "priority"
                businessRoutePriority
                "to"
                network
                "table"
                businessRouteTable
              ])
            ]
          )
          businessIPv4Networks
      );
    in
    sourceMove
    ++ targetMove
    ++ builtins.map (namespacedAddressCommand sourceNamespace sourceFinal) sourceAddresses
    ++ [
      (namespacedIpCommand sourceNamespace [ "link" "set" "dev" sourceFinal "up" ])
      (namespacedIpCommand targetNamespace [ "link" "set" "dev" targetFinal "up" ])
    ]
    ++ sourceRoutes
    ++ sourceNeighbors
    ++ targetRoutes
    ++ targetNeighbors
    ++ businessRouteCommands
    ++ peerDefaultRoutes
    ++ egressIPv6Commands;

  mkGatewayLinkService = link:
    let
      namespaceUnit = netnsUnit link.serviceName;
      devices = builtins.map deviceUnit [
        link.hostInterface
        link.serviceInterface
        enabledGateways.${link.gateway}.device
      ];
    in
    {
      description = "Attach ${link.serviceName}.${link.interfaceName} to gateway ${link.gateway}";
      bindsTo = [ namespaceUnit ];
      wants = [ "systemd-networkd.service" ] ++ devices;
      after = [ "systemd-networkd.service" ] ++ devices ++ [ namespaceUnit ];
      unitConfig.StopWhenUnneeded = true;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = gatewayStartCommands link;
        ExecStopPost =
          replyRoutingFirewallStopCommands link
          ++ replyRoutingStopCommands link
          ++ returnToInitialNamespace link.serviceName link.serviceInterface link.interfaceName;
      };
    };

  mkPeerLinkService = link:
    let
      sourceNamespace = serviceNamespace link.serviceName;
      targetNamespace =
        if link.targetIsHost then null else serviceNamespace link.targetService;
      namespaceUnits = unique (
        optional (sourceNamespace != null) (netnsUnit link.serviceName)
        ++ optional (targetNamespace != null) (netnsUnit link.targetService)
      );
      devices = builtins.map deviceUnit [
        link.sourceInterface
        link.targetInterface
      ];
      stopCommands =
        optionals (sourceNamespace != null)
          (
            returnToInitialNamespace link.serviceName link.sourceInterface link.interfaceName
          )
        ++ optionals (targetNamespace != null) (
          returnToInitialNamespace link.targetService link.targetInterface link.targetInterface
        );
    in
    {
      description = "Connect ${link.serviceName}.${link.interfaceName} to ${link.targetService}";
      bindsTo = namespaceUnits;
      wants = [ "systemd-networkd.service" ] ++ devices;
      after = [ "systemd-networkd.service" ] ++ devices ++ namespaceUnits;
      unitConfig.StopWhenUnneeded = true;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = peerStartCommands link;
        ExecStopPost = stopCommands;
      };
    };

  linkServices = builtins.listToAttrs (
    builtins.map
      (
        link:
        nameValuePair link.setupService (
          if link.type == "gateway" then mkGatewayLinkService link else mkPeerLinkService link
        )
      )
      allLinks
  );

  linksForService = serviceName:
    builtins.map (link: "${link.setupService}.service") (
      filter
        (
          link:
          link.type == "gateway" && link.serviceName == serviceName
          || link.type == "peer" && (
            builtins.any (member: member.serviceName == serviceName) link.members
            || link.targetService == serviceName
          )
        )
        allLinks
    );

  endpointsForService = serviceName:
    unique (
      builtins.map normalizeAddress (
        optional
          (enabledServices.${serviceName}.endpoint != null)
          enabledServices.${serviceName}.endpoint
        ++ concatMap
          (
            link: if link.targetService == serviceName then link.endpoints else [ ]
          )
          peerLinks
      )
    );

  servicesWithEndpoints = filterAttrs
    (
      serviceName: service:
        service.privateNetwork && endpointsForService serviceName != [ ]
    )
    enabledServices;

  endpointNamespaceServices = mapAttrs'
    (
      serviceName: _:
        let
          endpoints = endpointsForService serviceName;
        in
        nameValuePair "netns@${serviceName}" {
          overrideStrategy = "asDropin";
          serviceConfig.ExecStartPost = builtins.map
            (
              namespacedAddressCommand serviceName "lo"
            )
            endpoints;
        }
    )
    servicesWithEndpoints;

  applicationServices = mapAttrs'
    (
      serviceName: service:
        let
          namespaceUnit = netnsUnit serviceName;
          dependencies =
            optional service.privateNetwork namespaceUnit
            ++ linksForService serviceName;
          hostEndpoints =
            if service.privateNetwork then [ ] else endpointsForService serviceName;
        in
        nameValuePair service.unit (
          {
            bindsTo = dependencies;
            after = dependencies;
            serviceConfig.PrivateNetwork = service.privateNetwork;
          }
          // optionalAttrs service.privateNetwork {
            unitConfig.JoinsNamespaceOf = namespaceUnit;
          }
          // optionalAttrs (hostEndpoints != [ ]) {
            serviceConfig.ExecStartPre = builtins.map
              (
                namespacedAddressCommand null "lo"
              )
              hostEndpoints;
          }
        )
    )
    enabledServices;

  gatewayNetdevs = builtins.listToAttrs (
    builtins.map
      (
        link:
        nameValuePair "40-${link.setupService}" {
          netdevConfig = {
            Name = link.hostInterface;
            Kind = "veth";
            MACAddress = link.hostMac;
          };
          peerConfig = {
            Name = link.serviceInterface;
            MACAddress = link.serviceMac;
          };
        }
      )
      gatewayLinks
  );

  peerNetdevs = builtins.listToAttrs (
    builtins.map
      (
        link:
        nameValuePair "40-${link.setupService}" {
          netdevConfig = {
            Name = link.sourceInterface;
            Kind = "veth";
            MACAddress = link.sourceMac;
          };
          peerConfig = {
            Name = link.targetInterface;
            MACAddress = link.targetMac;
          };
        }
      )
      peerLinks
  );

  gatewayNetworks = builtins.listToAttrs (
    builtins.map
      (
        link:
        nameValuePair "40-${link.setupService}" {
          matchConfig.Name = link.hostInterface;
          linkConfig.RequiredForOnline = false;
          networkConfig = {
            Bridge = enabledGateways.${link.gateway}.device;
            ConfigureWithoutCarrier = true;
          };
        }
      )
      gatewayLinks
  );

  hostNetworkPeerLinks = filter
    (
      link: !link.service.privateNetwork
    )
    peerLinks;
  hostNetworkInputRules = concatMap
    (
      link:
      builtins.map
        (
          address:
          let
            nftFamily = if isIPv6 address then "ip6" else "ip";
            destination = addressIP address;
          in
          ''
            iifname "${link.sourceInterface}" ${nftFamily} daddr ${destination} accept
            ${nftFamily} daddr ${destination} drop
          ''
        )
        link.sourceAddresses
    )
    hostNetworkPeerLinks;

  interfaceAssertions = concatMap
    (
      link:
      let
        hasGateway = link.interface.gateway != null;
        hasPeer = link.interface.peer != null;
        peerIsHost = hasPeer && link.interface.peer.service == "host";
        peerExists = hasPeer && (
          peerIsHost || builtins.hasAttr link.interface.peer.service enabledServices
        );
        endpoints = if hasPeer then effectivePeerEndpoints link else [ ];
        addresses = effectiveAddresses link;
        egress = isEgressLink link;
        sourceFamilies = unique (builtins.map family addresses);
        endpointFamilies = unique (builtins.map family endpoints);
        sourceIPs = builtins.map (address: addressIP (normalizeAddress address)) addresses;
        endpointIPs = builtins.map (endpoint: addressIP (normalizeAddress endpoint)) endpoints;
        defaultRoute = link.interface.defaultRoute;
        inferredDefaultRoute = defaultRoute != null && defaultRoute.via == null;
        inferredRouteAddresses =
          if hasGateway && builtins.hasAttr link.interface.gateway enabledGateways then
            filter
              (
                address: builtins.elem (family address) sourceFamilies
              )
              enabledGateways.${link.interface.gateway}.addresses
          else if hasPeer then
            filter
              (
                address: builtins.elem (family address) sourceFamilies
              )
              endpoints
          else
            [ ];
        inferredRouteFamilies = builtins.map family inferredRouteAddresses;
      in
      [
        {
          assertion = hasGateway != hasPeer;
          message = "utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName} must set exactly one of gateway or peer.";
        }
        {
          assertion =
            builtins.stringLength link.interfaceName <= 15
            && builtins.match "[A-Za-z0-9_.-]+" link.interfaceName != null;
          message = "utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName} is not a valid Linux interface name.";
        }
        {
          assertion = addresses != [ ];
          message = "utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName}.addresses must not be empty.";
        }
        {
          assertion = !hasGateway || builtins.hasAttr link.interface.gateway enabledGateways;
          message = "utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName} refers to a missing or disabled gateway.";
        }
        {
          assertion = !hasPeer || peerExists;
          message = "utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName} refers to a missing or disabled peer service.";
        }
        {
          assertion = !hasPeer || link.interface.peer.service != link.serviceName;
          message = "utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName} cannot peer with itself.";
        }
        {
          assertion = !hasPeer || endpoints != [ ];
          message = "utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName} requires peer.endpoint or reusable endpoints on the peer service.";
        }
        {
          assertion = !hasPeer || all isHostPrefix (addresses ++ endpoints);
          message = "utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName} peer addresses must use /32 or /128 (bare addresses are accepted).";
        }
        {
          assertion =
            !hasPeer
            || (
              all (addressFamily: builtins.elem addressFamily endpointFamilies) sourceFamilies
              && all (addressFamily: builtins.elem addressFamily sourceFamilies) endpointFamilies
            );
          message = "utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName} and its peer endpoints must use the same address families.";
        }
        {
          assertion = !hasPeer || all (address: !(builtins.elem address endpointIPs)) sourceIPs;
          message = "utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName} must not reuse a peer endpoint as its local address.";
        }
        {
          assertion = link.interface.defaultRoute == null || hasGateway || egress;
          message = "utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName}.defaultRoute is only supported for gateway interfaces or host egress peers.";
        }
        {
          assertion =
            !replyRoutingEnabled link
            || all
              (
                sourceFamily:
                builtins.length
                  (
                    filter
                      (gatewayAddress: family gatewayAddress == sourceFamily)
                      enabledGateways.${link.interface.gateway}.addresses
                  )
                == 1
              )
              sourceFamilies;
          message = "Automatic reply routing for utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName} requires exactly one gateway address for each interface address family.";
        }
        {
          assertion = !(hasGateway && builtins.elem link.serviceName egressServiceNames && defaultRoute != null);
          message = "utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName} cannot provide a default route while the service uses host egress.";
        }
        {
          assertion =
            defaultRoute == null
            || defaultRoute.via == null
            || builtins.elem (family defaultRoute.via) sourceFamilies;
          message = "utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName}.defaultRoute must match one of the interface address families.";
        }
        {
          assertion = !inferredDefaultRoute || inferredRouteAddresses != [ ];
          message = "utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName}.defaultRoute cannot infer an address from its gateway.";
        }
        {
          assertion =
            !inferredDefaultRoute
            || builtins.length inferredRouteFamilies == builtins.length (unique inferredRouteFamilies);
          message = "utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName}.defaultRoute is ambiguous because its gateway has multiple matching addresses in one address family; set via explicitly.";
        }
        {
          assertion = !peerIsHost || egress;
          message = "utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName} may peer with host only as a default-route egress interface.";
        }
        {
          assertion = !hasGateway || link.service.privateNetwork;
          message = "Host-network services cannot attach to a utils.vnet gateway.";
        }
        {
          assertion =
            !hasPeer
            || peerIsHost
            || !(builtins.hasAttr link.interface.peer.service enabledServices)
            || link.service.privateNetwork
            || enabledServices.${link.interface.peer.service}.privateNetwork;
          message = "A peer link cannot connect two services that both use the host network namespace.";
        }
      ]
    )
    allRawLinks;

  serviceAssertions = concatMap
    (
      serviceName:
      let
        service = enabledServices.${serviceName};
        namespaceInterfaceNames =
          builtins.attrNames service.interfaces
          ++ optional (builtins.elem serviceName egressServiceNames) "vnet-egress"
          ++ builtins.map
            (link: link.targetInterface)
            (filter
              (
                link:
                !link.targetIsHost
                && link.targetService == serviceName
                && service.privateNetwork
              )
              peerLinks);
      in
      [
        {
          assertion = builtins.match "[A-Za-z0-9_.-]+" serviceName != null;
          message = "utils.vnet.services.${serviceName} is not a valid network namespace name.";
        }
        {
          assertion = service.endpoint == null || isHostPrefix service.endpoint;
          message = "utils.vnet.services.${serviceName}.endpoint must use /32 or /128 (a bare address is accepted).";
        }
        {
          assertion =
            !hasSuffix ".service" service.unit
            && builtins.match "[A-Za-z0-9@%:_.-]+" service.unit != null;
          message = "utils.vnet.services.${serviceName}.unit must be a systemd.services attribute name without the .service suffix.";
        }
        {
          assertion = service.privateNetwork || !service.egress.enable;
          message = "utils.vnet.services.${serviceName}.egress.enable requires privateNetwork = true.";
        }
        {
          assertion = cfg.egress.enable || !service.egress.enable;
          message = "utils.vnet.services.${serviceName}.egress.enable requires utils.vnet.egress.enable.";
        }
        {
          assertion = !builtins.hasAttr "vnet-egress" service.interfaces;
          message = "utils.vnet.services.${serviceName}.interfaces.vnet-egress is reserved for the automatic host transit peer.";
        }
        {
          assertion =
            !service.privateNetwork
            || builtins.length namespaceInterfaceNames
            == builtins.length (unique namespaceInterfaceNames);
          message = "Generated and declared interface names in the ${serviceName} network namespace must be unique.";
        }
      ]
    )
    (builtins.attrNames enabledServices);

  serviceUnits = builtins.map (service: service.unit) (builtins.attrValues enabledServices);
  uniqueServiceUnitAssertion = optional
    (
      builtins.length serviceUnits != builtins.length (unique serviceUnits)
    )
    {
      assertion = false;
      message = "Enabled utils.vnet.services entries must reference distinct systemd service units.";
    };

  generatedHostInterfaceNames = concatMap
    (
      link:
      if link.type == "gateway" then
        [ link.hostInterface link.serviceInterface ]
      else
        [ link.sourceInterface link.targetInterface ]
    )
    allLinks;
  uniqueGeneratedHostInterfaceAssertion = optional
    (
      builtins.length generatedHostInterfaceNames
      != builtins.length (unique generatedHostInterfaceNames)
    )
    {
      assertion = false;
      message = "Generated utils.vnet host interface names must remain unique after truncation.";
    };

  generatedLinkServiceNames = builtins.map (link: link.setupService) allLinks;
  generatedLinkServiceAssertions = [
    {
      assertion =
        builtins.length generatedLinkServiceNames
        == builtins.length (unique generatedLinkServiceNames);
      message = "Generated utils.vnet link service names must be unique.";
    }
    {
      assertion = builtins.all
        (name: builtins.stringLength name <= 247)
        generatedLinkServiceNames;
      message = "Generated utils.vnet link service names must fit within the systemd unit name limit.";
    }
  ];

  replyRoutingTableNames = builtins.map replyRoutingTableName (
    filter replyRoutingEnabled gatewayLinks
  );
  replyRoutingTableNameAssertion = {
    assertion =
      builtins.length replyRoutingTableNames
      == builtins.length (unique replyRoutingTableNames);
    message = "Generated utils.vnet reply-routing nft table names must be unique.";
  };

  hostNetworkNftablesAssertion = optional
    (
      hostNetworkPeerLinks != [ ] && !config.networking.nftables.enable
    )
    {
      assertion = false;
      message = "Host-network utils.vnet services require networking.nftables.enable to isolate their peer addresses.";
    };

  peerRouteAssertions = concatMap
    (
      targetService:
      let
        addresses = concatMap
          (
            link:
            if link.interface.peer.service == targetService then
              builtins.map (address: addressIP (normalizeAddress address)) (effectiveAddresses link)
            else
              [ ]
          )
          validPeerLinks;
      in
      optional (builtins.length addresses != builtins.length (unique addresses)) {
        assertion = false;
        message = "Peer addresses routed by utils.vnet.services.${targetService} must be unique.";
      }
    )
    (builtins.attrNames enabledServices);

  peerSourceAddressAssertions = concatMap
    (
      sourceService:
      let
        addresses = concatMap
          (
            link:
            if link.serviceName == sourceService then
              builtins.map (address: addressIP (normalizeAddress address)) (effectiveAddresses link)
            else
              [ ]
          )
          validPeerLinks;
      in
      optional (builtins.length addresses != builtins.length (unique addresses)) {
        assertion = false;
        message = "Peer interface addresses on utils.vnet.services.${sourceService} must be unique.";
      }
    )
    (builtins.attrNames enabledServices);
in
{
  options.utils.vnet.services = mkOption {
    type = with types; attrsOf (submoduleWith {
      modules = [ serviceModule ];
      specialArgs.vnetEgressPeerAddr = serviceName:
        if !cfg.egress.enable then
          ""
        else
          (vnetLib.parseIPv4Pool cfg.egress.ipv4.pool).addressAt (
            vnetLib.egressAddressId cfg.services serviceName
          );
    });
    default = { };
    description = "Systemd services with dedicated network namespaces and interfaces.";
  };

  config = mkIf (cfg.enable && enabledServices != { }) {
    assertions =
      interfaceAssertions
      ++ serviceAssertions
      ++ uniqueServiceUnitAssertion
      ++ uniqueGeneratedHostInterfaceAssertion
      ++ generatedLinkServiceAssertions
      ++ [ replyRoutingTableNameAssertion ]
      ++ hostNetworkNftablesAssertion
      ++ peerRouteAssertions
      ++ peerSourceAddressAssertions;

    systemd.network.netdevs = gatewayNetdevs // peerNetdevs;
    systemd.network.networks = gatewayNetworks;

    systemd.services = mkMerge [
      linkServices
      endpointNamespaceServices
      applicationServices
    ];

    networking.nftables.tables = optionalAttrs (hostNetworkPeerLinks != [ ]) {
      vnet-host-services = {
        family = "inet";
        content = ''
          chain input {
            type filter hook input priority -20; policy accept;

            ${concatStringsSep "\n" hostNetworkInputRules}
          }
        '';
      };
    };
  };
}
