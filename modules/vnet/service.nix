{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  inherit (lib)
    all
    concatMap
    concatStringsSep
    filter
    filterAttrs
    hasInfix
    hasSuffix
    mapAttrs'
    mapAttrsToList
    mkIf
    mkMerge
    mkOption
    nameValuePair
    optional
    optionals
    splitString
    types
    unique
    ;

  cfg = config.utils.vnet;
  enabledServices = filterAttrs (_: service: service.enable) cfg.services;
  enabledGateways = filterAttrs (_: gateway: gateway.enable) cfg.gateways;
  inherit (import ./types.nix) serviceModule;

  ip = "${pkgs.iproute2}/bin/ip";
  waitOnline = "${config.systemd.package}/lib/systemd/systemd-networkd-wait-online";

  hash = value: builtins.hashString "sha256" value;
  shortHash = value: builtins.substring 0 11 (hash value);
  kernelName = prefix: value: "${prefix}${builtins.substring 0 (15 - builtins.stringLength prefix) (hash value)}";
  gatewayDevice = name: kernelName "gw" "gateway:${name}";

  macAddress = value:
    let
      digest = hash value;
    in
    concatStringsSep ":" [
      "02"
      (builtins.substring 0 2 digest)
      (builtins.substring 2 2 digest)
      (builtins.substring 4 2 digest)
      (builtins.substring 6 2 digest)
      (builtins.substring 8 2 digest)
    ];

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

  rawLinks = concatMap (
    serviceName:
    mapAttrsToList (interfaceName: interface: {
      key = "${serviceName}:${interfaceName}";
      inherit interfaceName interface serviceName;
      service = enabledServices.${serviceName};
    }) enabledServices.${serviceName}.interfaces
  ) (builtins.attrNames enabledServices);

  validGatewayLinks = filter (
    link: link.interface.gateway != null && link.interface.peer == null
  ) rawLinks;
  validPeerLinks = filter (
    link: link.interface.peer != null && link.interface.gateway == null
  ) rawLinks;

  effectivePeerEndpoints = link:
    if link.interface.peer.endpoint != null then
      [ link.interface.peer.endpoint ]
    else if
      builtins.hasAttr link.interface.peer.service enabledServices
      && enabledServices.${link.interface.peer.service}.endpoint != null
    then
      [ enabledServices.${link.interface.peer.service}.endpoint ]
    else
      [ ];

  gatewayLinks = builtins.map (
    link:
    let
      linkHash = shortHash "gateway-link:${link.key}";
    in
    link
    // {
      type = "gateway";
      setupService = "netns-link-${linkHash}";
      unit = "netns-link-${linkHash}.service";
      hostInterface = kernelName "gh" "gateway-host:${link.key}";
      serviceInterface = kernelName "gs" "gateway-service:${link.key}";
      hostMac = macAddress "gateway-host:${link.key}";
      serviceMac = macAddress "gateway-service:${link.key}";
      gateway = link.interface.gateway;
    }
  ) validGatewayLinks;

  peerLinks = builtins.map (
    link:
    let
      linkHash = shortHash "peer-link:${link.key}";
    in
    link
    // {
      type = "peer";
      setupService = "netns-link-${linkHash}";
      unit = "netns-link-${linkHash}.service";
      sourceInterface = kernelName "p0" "peer-source:${link.key}";
      targetInterface = kernelName "p1" "peer-target:${link.key}";
      targetFinalInterface = "peer-${builtins.substring 0 10 (hash link.key)}";
      sourceMac = macAddress "peer-source:${link.key}";
      targetMac = macAddress "peer-target:${link.key}";
      targetService = link.interface.peer.service;
      endpoints = effectivePeerEndpoints link;
    }
  ) validPeerLinks;

  allLinks = gatewayLinks ++ peerLinks;

  firstAddress = addressFamily: addresses:
    let
      matching = filter (address: family address == addressFamily) addresses;
    in
    if matching == [ ] then
      (if addressFamily == "ipv6" then "::" else "0.0.0.0")
    else
      addressIP (builtins.head matching);

  moveAndRename = namespace: temporary: final: [
    (ipCommand [ "link" "set" "dev" temporary "netns" namespace ])
    (ipCommand [ "-n" namespace "link" "set" "dev" temporary "name" final ])
  ];

  returnToInitialNamespace = namespace: temporary: final: [
    (ignored (ipCommand [ "-n" namespace "link" "set" "dev" final "name" temporary ]))
    (ignored (ipCommand [ "-n" namespace "link" "set" "dev" temporary "netns" "1" ]))
  ];

  addressCommand = namespace: interface: address:
    ipCommand (
      [ "-n" namespace "address" "replace" (normalizeAddress address) "dev" interface ]
      ++ optionals (isIPv6 address) [ "nodad" ]
    );

  addressCommands = namespace: interface: addresses:
    builtins.map (addressCommand namespace interface) addresses;

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
      filter (
        address: builtins.elem (family address) sourceFamilies
      ) enabledGateways.${link.gateway}.addresses
    else
      [ ];

  gatewayStartCommands = link:
    let
      namespace = link.serviceName;
      interface = link.interfaceName;
      defaultRoute = link.interface.defaultRoute;
      routeCommands = concatMap (
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
      ) (defaultRouteAddresses link);
    in
    moveAndRename namespace link.serviceInterface interface
    ++ addressCommands namespace interface link.interface.addresses
    ++ [ (ipCommand [ "-n" namespace "link" "set" "dev" interface "up" ]) ]
    ++ routeCommands
    ++ [
      ("${waitOnline} ${utils.escapeSystemdExecArgs [
        "--interface=${link.hostInterface}:enslaved"
        "--timeout=30"
      ]}")
    ];

  peerStartCommands = link:
    let
      sourceNamespace = link.serviceName;
      targetNamespace = link.targetService;
      sourceFinal = link.interfaceName;
      targetFinal = link.targetFinalInterface;
      sourceAddresses = builtins.map normalizeAddress link.interface.addresses;
      targetEndpoints = builtins.map normalizeAddress link.endpoints;

      sourceRoutes = builtins.map (
        endpoint:
        ipCommand [
          "-n"
          sourceNamespace
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
      ) targetEndpoints;
      sourceNeighbors = builtins.map (
        endpoint:
        ipCommand [
          "-n"
          sourceNamespace
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
      ) targetEndpoints;
      targetRoutes = builtins.map (
        address:
        ipCommand [
          "-n"
          targetNamespace
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
      ) sourceAddresses;
      targetNeighbors = builtins.map (
        address:
        ipCommand [
          "-n"
          targetNamespace
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
      ) sourceAddresses;
    in
    moveAndRename sourceNamespace link.sourceInterface sourceFinal
    ++ moveAndRename targetNamespace link.targetInterface targetFinal
    ++ addressCommands sourceNamespace sourceFinal sourceAddresses
    ++ [
      (ipCommand [ "-n" sourceNamespace "link" "set" "dev" sourceFinal "up" ])
      (ipCommand [ "-n" targetNamespace "link" "set" "dev" targetFinal "up" ])
    ]
    ++ sourceRoutes
    ++ sourceNeighbors
    ++ targetRoutes
    ++ targetNeighbors;

  mkGatewayLinkService = link:
    let
      namespaceUnit = netnsUnit link.serviceName;
      devices = builtins.map deviceUnit [
        link.hostInterface
        link.serviceInterface
        (gatewayDevice link.gateway)
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
        ExecStopPost = returnToInitialNamespace link.serviceName link.serviceInterface link.interfaceName;
      };
    };

  mkPeerLinkService = link:
    let
      namespaceUnits = unique [
        (netnsUnit link.serviceName)
        (netnsUnit link.targetService)
      ];
      devices = builtins.map deviceUnit [
        link.sourceInterface
        link.targetInterface
      ];
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
        ExecStopPost =
          returnToInitialNamespace link.serviceName link.sourceInterface link.interfaceName
          ++ returnToInitialNamespace link.targetService link.targetInterface link.targetFinalInterface;
      };
    };

  linkServices = builtins.listToAttrs (
    builtins.map (
      link:
      nameValuePair link.setupService (
        if link.type == "gateway" then mkGatewayLinkService link else mkPeerLinkService link
      )
    ) allLinks
  );

  linksForService = serviceName:
    builtins.map (link: link.unit) (
      filter (
        link:
        link.serviceName == serviceName || (link.type == "peer" && link.targetService == serviceName)
      ) allLinks
    );

  endpointsForService = serviceName:
    unique (
      builtins.map normalizeAddress (
        optional
          (enabledServices.${serviceName}.endpoint != null)
          enabledServices.${serviceName}.endpoint
        ++ concatMap (
          link: if link.targetService == serviceName then link.endpoints else [ ]
        ) peerLinks
      )
    );

  servicesWithEndpoints = filterAttrs (
    serviceName: _: endpointsForService serviceName != [ ]
  ) enabledServices;

  endpointNamespaceServices = mapAttrs' (
    serviceName: _:
    let
      endpoints = endpointsForService serviceName;
    in
    nameValuePair "netns@${serviceName}" {
      overrideStrategy = "asDropin";
      serviceConfig.ExecStartPost = builtins.map (
        addressCommand serviceName "lo"
      ) endpoints;
    }
  ) servicesWithEndpoints;

  applicationServices = mapAttrs' (
    serviceName: service:
    let
      namespaceUnit = netnsUnit serviceName;
      dependencies = [ namespaceUnit ] ++ linksForService serviceName;
    in
    nameValuePair service.unit {
      bindsTo = dependencies;
      after = dependencies;
      unitConfig.JoinsNamespaceOf = namespaceUnit;
      serviceConfig.PrivateNetwork = true;
    }
  ) enabledServices;

  gatewayNetdevs = builtins.listToAttrs (
    builtins.map (
      link:
      nameValuePair "40-netns-link-${shortHash link.key}" {
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
    ) gatewayLinks
  );

  peerNetdevs = builtins.listToAttrs (
    builtins.map (
      link:
      nameValuePair "40-netns-link-${shortHash link.key}" {
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
    ) peerLinks
  );

  gatewayNetworks = builtins.listToAttrs (
    builtins.map (
      link:
      nameValuePair "40-netns-link-${shortHash link.key}" {
        matchConfig.Name = link.hostInterface;
        linkConfig.RequiredForOnline = false;
        networkConfig = {
          Bridge = gatewayDevice link.gateway;
          ConfigureWithoutCarrier = true;
        };
      }
    ) gatewayLinks
  );

  interfaceAssertions = concatMap (
    link:
    let
      hasGateway = link.interface.gateway != null;
      hasPeer = link.interface.peer != null;
      peerExists = hasPeer && builtins.hasAttr link.interface.peer.service enabledServices;
      endpoints = if hasPeer then effectivePeerEndpoints link else [ ];
      sourceFamilies = unique (builtins.map family link.interface.addresses);
      endpointFamilies = unique (builtins.map family endpoints);
      sourceIPs = builtins.map (address: addressIP (normalizeAddress address)) link.interface.addresses;
      endpointIPs = builtins.map (endpoint: addressIP (normalizeAddress endpoint)) endpoints;
      defaultRoute = link.interface.defaultRoute;
      inferredDefaultRoute = defaultRoute != null && defaultRoute.via == null;
      inferredRouteAddresses =
        if hasGateway && builtins.hasAttr link.interface.gateway enabledGateways then
          filter (
            address: builtins.elem (family address) sourceFamilies
          ) enabledGateways.${link.interface.gateway}.addresses
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
        assertion = link.interface.addresses != [ ];
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
        assertion = !hasPeer || all isHostPrefix (link.interface.addresses ++ endpoints);
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
        assertion = link.interface.defaultRoute == null || hasGateway;
        message = "utils.vnet.services.${link.serviceName}.interfaces.${link.interfaceName}.defaultRoute is only supported for gateway interfaces.";
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
    ]
  ) rawLinks;

  serviceAssertions = concatMap (
    serviceName:
    let
      service = enabledServices.${serviceName};
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
    ]
  ) (builtins.attrNames enabledServices);

  serviceUnits = builtins.map (service: service.unit) (builtins.attrValues enabledServices);
  uniqueServiceUnitAssertion = optional (
    builtins.length serviceUnits != builtins.length (unique serviceUnits)
  ) {
    assertion = false;
    message = "Enabled utils.vnet.services entries must reference distinct systemd service units.";
  };

  peerRouteAssertions = concatMap (
    targetService:
    let
      addresses = concatMap (
        link:
        if link.targetService == targetService then
          builtins.map (address: addressIP (normalizeAddress address)) link.interface.addresses
        else
          [ ]
      ) peerLinks;
    in
    optional (builtins.length addresses != builtins.length (unique addresses)) {
      assertion = false;
      message = "Peer addresses routed by utils.vnet.services.${targetService} must be unique.";
    }
  ) (builtins.attrNames enabledServices);

  peerSourceAddressAssertions = concatMap (
    sourceService:
    let
      addresses = concatMap (
        link:
        if link.serviceName == sourceService then
          builtins.map (address: addressIP (normalizeAddress address)) link.interface.addresses
        else
          [ ]
      ) peerLinks;
    in
    optional (builtins.length addresses != builtins.length (unique addresses)) {
      assertion = false;
      message = "Peer interface addresses on utils.vnet.services.${sourceService} must be unique.";
    }
  ) (builtins.attrNames enabledServices);
in
{
  options.utils.vnet.services = mkOption {
    type = with types; attrsOf (submodule serviceModule);
    default = { };
    description = "Systemd services with dedicated network namespaces and interfaces.";
  };

  config = mkIf (cfg.enable && enabledServices != { }) {
    assertions =
      interfaceAssertions
      ++ serviceAssertions
      ++ uniqueServiceUnitAssertion
      ++ peerRouteAssertions
      ++ peerSourceAddressAssertions;

    systemd.network.netdevs = gatewayNetdevs // peerNetdevs;
    systemd.network.networks = gatewayNetworks;

    systemd.services = mkMerge [
      linkServices
      endpointNamespaceServices
      applicationServices
    ];
  };
}
