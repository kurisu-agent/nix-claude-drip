# claude-drip release cache — a pull-through HTTP cache in front of the Claude
# Code release channel, so a fleet of machines pulls each new version across the
# WAN once instead of once per machine. Claude Code ships ~daily and the native
# binary is ~262 MiB, so the second machine onwards is the whole saving.
#
# It is a DUMB caching reverse proxy, and that is the entire reason this module
# is small: it runs no timer, polls nothing, and knows nothing about versions,
# manifests, checksums, or the release schedule. Clients keep every bit of their
# existing fetch logic — channel pointer, per-version manifest, SHA-256
# verification, atomic swap — and simply point `releaseBase` at this host. Which
# also means the rollback is pointing `releaseBase` back at the upstream.
#
# Independent of the client module on purpose: a cache host need not run Claude
# Code, and a client machine need not grow an nginx option surface it will never
# use, so `nixosModules.default` does not import this one.
{
  config,
  lib,
  ...
}:

let
  cfg = config.services.claude-code-cache;

  # nginx wants the upstream in three different shapes, so it gets split once,
  # here:
  #   origin    — "https://host[:port]", the only part proxy_pass is given;
  #   authority — "host[:port]", for the Host header and hence the TLS SNI;
  #   path      — "/claude-code-releases", the prefix that has to be put back
  #               onto the front of every proxied request URI.
  # The pattern is anchored and total, so a malformed `upstream` trips the
  # assertion below instead of quietly producing a broken nginx config.
  upstreamMatch = builtins.match "(https?://([^/]+))(/.*)?" (lib.removeSuffix "/" cfg.upstream);

  # A group that did not participate — and every group of a URL that failed to
  # match — reads as null, but evaluation still has to get far enough for the
  # assertion to be the error the operator actually sees. So every read goes
  # through here and lands on "" rather than throwing.
  upstreamGroup =
    i:
    let
      g = if upstreamMatch == null then null else builtins.elemAt upstreamMatch i;
    in
    if g == null then "" else g;

  upstreamOrigin = upstreamGroup 0;
  upstreamAuthority = upstreamGroup 1;
  upstreamPath = upstreamGroup 2;

  # One cache, one shared-memory zone, one name for both.
  zone = "claude_code_cache";

  # Bound to loopback the cache is unreachable from the fleet whatever the
  # firewall says. That is a warning rather than an assertion, because it is
  # also a perfectly good way to try the module out on a single machine.
  loopbackOnly = cfg.listenAddress == "127.0.0.1" || cfg.listenAddress == "::1";

  # `<version>/manifest.json` and `<version>/<platform>/claude` never change for
  # a given version, so their freshness lifetime is a formality — it only has to
  # sit comfortably past any plausible `inactive`, because disuse is what
  # actually reclaims them (see the proxy_cache_path comment below).
  immutableTtl = "365d";

  # With no resolver configured, proxy_pass names the upstream literally and
  # nginx resolves it once, at startup; with one configured it gets a variable
  # instead, which is what forces a lookup per request. The `resolver` option
  # description spells out why that is the operator's choice and not ours.
  proxyTarget = if cfg.resolver == [ ] then upstreamOrigin else "$claude_code_cache_upstream";

  # Everything a proxied location needs except how long the response stays
  # fresh — which is the only axis this URL space splits on, so it is the only
  # parameter. Written as raw extraConfig rather than the module's `proxyPass`
  # option because that option would also drag in `recommendedProxySettings`
  # (which sets `Host $host` — exactly the header we have to override) and, if
  # `services.nginx.proxyResolveWhileRunning` were on, a second and conflicting
  # opinion about the variable-vs-literal question handled above.
  proxyLocation = ttl: {
    extraConfig = ''
      ${lib.optionalString (upstreamPath != "") ''
        # proxy_pass may not carry a URI part inside a regex location, and the
        # variable form ignores one, so the upstream's own path prefix is put
        # back onto the request URI here instead — which keeps both locations,
        # in both resolver modes, to a single shape. $uri is the decoded path,
        # lossless for a URL space of version numbers, platform names and
        # "manifest.json"; query arguments survive because the replacement
        # contains no "?", so nginx re-appends them.
        rewrite ^ ${upstreamPath}$uri break;
      ''}
      proxy_pass ${proxyTarget};
      proxy_http_version 1.1;

      # Caching only ever happens on a buffered response. State it rather than
      # inherit it: a `proxy_buffering off` set anywhere above would otherwise
      # quietly demote this whole module to a plain reverse proxy.
      proxy_buffering on;

      # The upstream is a virtual-hosted TLS CDN. Without an explicit Host
      # header nginx would forward the client's — this cache's own address —
      # and without proxy_ssl_server_name it would open the TLS connection with
      # no SNI at all. Both have to carry the origin's name, not ours.
      proxy_set_header Host ${upstreamAuthority};
      proxy_ssl_server_name on;

      # Clients speak plain HTTP to this cache, so the upstream handshake is the
      # only place a release can still be authenticated — verify it against the
      # system trust store. An internal mirror behind a private CA works as soon
      # as that CA is in `security.pki.certificateFiles`.
      proxy_ssl_verify on;
      proxy_ssl_trusted_certificate ${config.security.pki.caBundle};
      proxy_ssl_verify_depth 5;

      proxy_cache ${zone};
      proxy_cache_valid 200 ${ttl};

      # That TTL is the policy, because this module knows the mutability of the
      # URL space better than a generic CDN header does. Left to itself, one
      # `Cache-Control: no-cache` — or a stray Set-Cookie — on the upstream
      # response would silently switch the whole cache off.
      proxy_ignore_headers X-Accel-Expires Cache-Control Expires Set-Cookie;

      # N machines booting at once collapse onto ONE upstream fetch: the first
      # request through populates the entry and the rest wait on it. The lock
      # windows are minutes rather than nginx's 5 s defaults because the payload
      # is ~262 MiB over the WAN — but deliberately under the updater's own
      # `curl --max-time 300`, so a queued client still gets served from the
      # finished entry instead of timing out while waiting for it.
      proxy_cache_lock on;
      proxy_cache_lock_age 180s;
      proxy_cache_lock_timeout 180s;

      # A WAN blip serves the copy we already have rather than failing the
      # client, and a pointer refresh never blocks anyone: the stale value goes
      # out immediately while the revalidation runs behind it. Revalidation
      # itself is conditional, so a pointer that has not moved costs a 304.
      proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
      proxy_cache_background_update on;
      proxy_cache_revalidate on;

      # The only way an operator can tell this is working:
      #   curl -sI http://<host>:<port>/latest | grep -i x-cache-status
      add_header X-Cache-Status $upstream_cache_status always;
    '';
  };
in
{
  options.services.claude-code-cache = {
    enable = lib.mkEnableOption ''
      the claude-drip release cache — a pull-through HTTP cache in front of the
      Claude Code release channel, so a fleet fetches each new version across
      the WAN once. It is a plain caching reverse proxy: it polls nothing and
      knows nothing about versions, so clients keep their normal fetch and
      verification path and only have their `releaseBase` pointed at
      `http://<this host>:<port>`. Enabling this also enables
      `services.nginx`, where it registers a virtual host of its own alongside
      any others already configured on the machine
    '';

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = ''
        Address the cache listens on. The default binds loopback only, which is
        useless to a fleet but safe on a machine that has just been rebuilt —
        the cache serves plain HTTP and authenticates nobody, so exposing it is
        meant to be a deliberate act. Set it to an address the other machines
        can reach, or "0.0.0.0" for every interface, once you know the network
        it sits on is one you trust.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8502;
      description = ''
        TCP port for the cache's virtual host. It gets a socket to itself
        rather than sharing :80 so that the cache can live on a machine that is
        already serving other nginx virtual hosts without disturbing them or
        needing a name to be routed by.
      '';
    };

    upstream = lib.mkOption {
      type = lib.types.str;
      default = "https://downloads.claude.ai/claude-code-releases";
      description = ''
        The release channel this cache pulls from — the same URL a client would
        otherwise fetch directly, and the default is exactly the client
        default. Point it at another cache to chain them (a site cache in front
        of a rack cache), or at an internal mirror. Any path prefix in the URL
        is preserved: it is re-attached to each proxied request, so clients
        always address this cache at its root no matter how deep the upstream
        sits.
      '';
    };

    cacheDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/cache/claude-code-cache";
      description = ''
        Directory holding the cached responses. It is created for the nginx
        user and punched through nginx's systemd sandbox on activation, so it
        can live anywhere with room for it. Budget `maxSize` plus a little:
        responses are written straight into this tree rather than staged
        elsewhere and copied in. Nothing here is precious — deleting the lot
        costs one WAN fetch per version still in use.
      '';
    };

    maxSize = lib.mkOption {
      type = lib.types.str;
      default = "2g";
      example = "512m";
      description = ''
        Ceiling on the size of the cache tree, in nginx's size syntax. This is
        a backstop rather than a working-set estimate: entries are normally
        reclaimed by `inactive` long before the total approaches it, because a
        superseded version is never requested again. A version of the binary
        plus its manifest is a few hundred megabytes, so the default leaves
        room for a fleet straggling across several at once. Past the ceiling,
        nginx's cache manager evicts least-recently-used entries.
      '';
    };

    inactive = lib.mkOption {
      type = lib.types.str;
      default = "7d";
      example = "30d";
      description = ''
        How long an entry survives without being requested, in nginx's time
        syntax. This is what actually reclaims disk here: the moment a new
        version ships, the previous manifest and binary stop being asked for
        and simply age out. Raise it if machines in the fleet go weeks between
        boots and you would rather they still land on a warm cache; lower it to
        keep the tree small.
      '';
    };

    channelTtl = lib.mkOption {
      type = lib.types.str;
      default = "1m";
      example = "5m";
      description = ''
        How long a cached channel pointer stays fresh, in nginx's time syntax.
        This is the one knob trading WAN traffic against how promptly the fleet
        notices a release: at the default, a machine learns about a new version
        at most a minute after the first machine to ask does, and the fleet's
        combined polling collapses to one upstream request a minute. The
        pointer is a handful of bytes, so there is little to win by raising it.
        Per-version manifests and binaries are immutable and stay cached
        effectively forever regardless of this setting.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open `port` in the host firewall. Off by default, and on its own it
        achieves nothing while `listenAddress` is still loopback — the cache is
        unauthenticated plain HTTP, so both halves of exposing it are meant to
        be separate, deliberate steps.
      '';
    };

    resolver = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "10.0.0.1"
        "valid=30s"
      ];
      description = ''
        DNS servers nginx should use to re-resolve the upstream while running,
        and the one real tradeoff in this module.

        Empty — the default — names the upstream in `proxy_pass` literally, so
        nginx resolves it once at startup and holds that address until it is
        reloaded or restarted. That works on every network, including ones with
        no reachable public resolver, but it goes stale against a CDN that
        rotates addresses; the symptom is a cache that worked yesterday and now
        times out, cured by `systemctl reload nginx`.

        A non-empty list switches `proxy_pass` to its variable form, which
        re-resolves per request and follows rotation on its own. But that form
        *requires* a resolver directive, and there is no defensible default to
        hardcode — a public resolver would be the wrong answer, and often an
        unreachable one, on a restricted network. So you name it. Entries are
        passed through verbatim and in order, which is also how you append
        nginx's own parameters, such as `valid=30s` or `ipv6=off`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.nginx.enable = true;

    services.nginx.appendHttpConfig = ''
      # `levels=1:2` keeps the directory fan-out sane; `use_temp_path=off` has
      # nginx write the response straight into the cache tree instead of
      # staging it under nginx's own temp path and copying it across, which for
      # a ~262 MiB binary is a whole pointless second write.
      #
      # EVICTION IS FREE, which is why there is no pruning logic anywhere in
      # this module: once a new version ships, nothing ever asks for the
      # previous manifest or binary again, so `inactive=` reclaims them purely
      # by disuse. `max_size=` is only the backstop for the pathological case
      # of a fleet spread across many versions at once.
      proxy_cache_path ${cfg.cacheDir} levels=1:2 keys_zone=${zone}:10m max_size=${cfg.maxSize} inactive=${cfg.inactive} use_temp_path=off;
    '';

    # The vhost is the only thing on its address:port, so it is that socket's
    # default server and the server_name never has to match anything — clients
    # address it by IP.
    services.nginx.virtualHosts.claude-code-cache = {
      listen = [
        {
          addr = cfg.listenAddress;
          inherit (cfg) port;
        }
      ];

      extraConfig = lib.optionalString (cfg.resolver != [ ]) ''
        # Scoped to this server rather than set through `services.nginx.resolver`,
        # which is http-wide and would silently change how every other virtual
        # host on this machine resolves its own upstreams.
        resolver ${lib.concatStringsSep " " cfg.resolver};

        # proxy_pass only re-resolves when its argument contains a variable.
        # That is the entire reason this indirection exists.
        set $claude_code_cache_upstream "${upstreamOrigin}";
      '';

      locations = {
        # The channel pointer. Rather than name the channels — this module
        # knows none of them — match their shape: a pointer is a single path
        # segment at the root, while everything immutable lives under a version
        # directory and so carries a second slash. A regex location outranks
        # the prefix one below, so this wins for `/latest`, `/stable`, or
        # whatever a channel is called next.
        "~ ^/[^/]+$" = proxyLocation cfg.channelTtl;

        # Everything under a version: `<version>/manifest.json` and
        # `<version>/<platform>/claude`. A released version is never rebuilt,
        # so these are cached until they are evicted rather than until they
        # expire.
        "/" = proxyLocation immutableTtl;
      };
    };

    # nginx runs under ProtectSystem=strict and grants itself only its own
    # /var/log/nginx and /var/cache/nginx, so a cacheDir anywhere else has to be
    # both created for it — the master process runs as the nginx user and
    # cannot mkdir it itself — and punched through the sandbox. ReadWritePaths
    # merges by concatenation, so this adds to rather than replaces whatever
    # else has been granted.
    systemd.tmpfiles.rules = [
      "d ${cfg.cacheDir} 0750 ${config.services.nginx.user} ${config.services.nginx.group} -"
    ];
    systemd.services.nginx.serviceConfig.ReadWritePaths = [ cfg.cacheDir ];

    networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;

    assertions = [
      {
        assertion = upstreamMatch != null;
        message = ''
          services.claude-code-cache.upstream must be an http:// or https:// URL
          (optionally with a path), e.g. "https://downloads.claude.ai/claude-code-releases".
          Got: "${cfg.upstream}"
        '';
      }
    ];

    warnings = lib.optional (cfg.openFirewall && loopbackOnly) ''
      services.claude-code-cache.openFirewall is set while listenAddress is
      "${cfg.listenAddress}", so the port is still reachable only from this
      machine. Set listenAddress to an address the fleet can reach.
    '';
  };
}
