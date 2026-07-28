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

  # The upstream with any trailing slash removed, so the location targets below
  # can each append exactly one.
  upstreamBase = lib.removeSuffix "/" cfg.upstream;

  # The one piece nginx needs that `upstreamBase` cannot give it directly: the
  # authority, "host[:port]", for the Host header and hence the TLS SNI. The
  # location targets use `upstreamBase` verbatim, so nothing else is extracted.
  # The pattern is anchored and total, so a malformed `upstream` trips the
  # assertion below instead of quietly producing a broken nginx config.
  upstreamMatch = builtins.match "(https?://([^/]+))(/.*)?" upstreamBase;

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

  upstreamAuthority = upstreamGroup 1;

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

  # Everything a proxied location needs except its upstream target and how long
  # the response stays fresh. Written as raw extraConfig rather than the
  # module's `proxyPass` option because that option would also drag in
  # `recommendedProxySettings`, which sets `Host $host` — exactly the header
  # this module has to override.
  #
  # WHY EVERY LOCATION IS A PREFIX OR EXACT MATCH, AND WHY NOTHING REWRITES.
  # The obvious shape for this cache is one regex location for the channel
  # pointer and one catch-all for everything else, with the upstream's own path
  # prefix (`/claude-code-releases`) glued back on by `rewrite ^ <prefix>$uri`.
  # That is a security bug, and NixOS's own nginx config linter rejects it:
  # `$uri` is the DECODED request path, so a client asking for `/x%0aHeader:%20v`
  # puts a real newline into the rewritten URI and thereby into the request line
  # sent upstream — HTTP request splitting. Reconstructing a proxied URI from
  # any client-controlled variable has the same flaw.
  #
  # So the prefix is never reassembled at all. nginx's own prefix-location
  # substitution does it: for a location with a URI in `proxy_pass`, the part of
  # the request matching the location is replaced by that URI, entirely inside
  # nginx and with no variable in sight. That works for prefix and exact
  # locations, and is the one thing a REGEX location may not do — which is
  # precisely why the channel pointers are matched exactly by name instead.
  proxyLocation = target: ttl: {
    extraConfig = ''
      proxy_pass ${target};
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
      # windows are far longer than nginx's 5 s defaults because the payload is
      # ~262 MiB over the WAN, and far SHORTER than they could be because of
      # what waiting costs the client.
      #
      # THE CEILING IS THE CLIENT'S STALL DETECTOR, NOT THIS CACHE. A queued
      # request receives NOTHING — not a byte, not a header — for as long as it
      # is held here, and curl's `--speed-limit`/`--speed-time` pair starts
      # counting from the moment the request is in flight rather than from the
      # first body byte. So a held client reads as "0 bytes/sec" and is killed
      # by its own timeout: measured directly against a server that withheld
      # its headers, a curl carrying `--speed-limit 4096 --speed-time 30` died
      # at exactly 30 s with "Operation too slow". Held too long, this lock
      # therefore destroys precisely the fleet-boot herd it exists to protect.
      #
      # 45 s sits under the 120 s stall window the sibling updater in this
      # flake now uses (lib/claude.nix), with room for a client whose window is
      # tighter still. Past it nginx releases the queued request to the
      # upstream — a WAN fetch that the lock would rather have avoided, but a
      # served client beats a collapsed one. The two figures are a pair; moving
      # this one above any client's stall window silently reintroduces the bug.
      proxy_cache_lock on;
      proxy_cache_lock_age 45s;
      proxy_cache_lock_timeout 45s;

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
        is preserved: nginx substitutes it for the matched part of each
        request, so clients always address this cache at its root no matter how
        deep the upstream sits.

        The name here is resolved ONCE, when nginx starts, and that address is
        held until nginx is reloaded — the ordinary consequence of naming an
        upstream literally in `proxy_pass`. Against a CDN that rotates
        addresses this can eventually go stale; the symptom is a cache that
        worked yesterday and now times out, and `systemctl reload nginx` cures
        it (a `nixos-rebuild switch` does so as a side effect). The alternative
        — nginx's variable form of `proxy_pass`, which re-resolves per request
        — is deliberately NOT offered here, because it cannot apply the
        upstream's path prefix without rebuilding the request URI from a
        client-controlled variable, which is the request-splitting hazard
        documented above `proxyLocation`.
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

    channels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "latest"
        "stable"
      ];
      description = ''
        The channel-pointer names, each of which gets its own exactly-matched
        location cached for `channelTtl`. EVERY OTHER PATH is treated as
        immutable and cached until it is evicted, which is correct for the
        per-version manifests and binaries that make up the rest of this URL
        space — and wrong for a channel not named here, which would be pinned
        for a year. So if a new channel appears, add it.

        Naming them, rather than matching "a single path segment at the root"
        with a regex, is what lets this module hand the upstream's path prefix
        to nginx's own prefix substitution instead of rebuilding the URI from
        `$uri` — see the comment above `proxyLocation` for why rebuilding it is
        a request-splitting hazard.
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

      locations =
        # The channel pointers, one exactly-matched location each. An exact
        # match outranks the prefix location below, so these win for their own
        # names and nothing else is affected.
        lib.listToAttrs (
          map (c: lib.nameValuePair "= /${c}" (proxyLocation "${upstreamBase}/${c}" cfg.channelTtl))
            cfg.channels
        )
        // {
          # Everything else: `<version>/manifest.json` and
          # `<version>/<platform>/claude`. A released version is never rebuilt,
          # so these are cached until they are evicted rather than until they
          # expire. The trailing slash on both sides is what makes nginx
          # substitute the upstream's path prefix for the matched "/" — the
          # whole reason no rewrite is needed.
          "/" = proxyLocation "${upstreamBase}/" immutableTtl;
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
