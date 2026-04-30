# ── Stage 1: Build with Nix ──────────────────────────────────────────
FROM nixos/nix AS build

RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

WORKDIR /app

# ── 1a. Flake layer (cached unless flake inputs change) ─────────────
COPY flake.nix flake.lock ./
RUN git init && git add flake.nix flake.lock

# Pre-fetch the flake's nix store closure so this layer is cached
RUN nix develop --profile /tmp/devshell-cache --command true

# ── 1b. Gem source + bundle install ────────────────────────────────
COPY caldav.gemspec Gemfile Gemfile.lock LICENSE ./
COPY lib/ lib/
COPY example/Gemfile example/Gemfile.lock example/

RUN git add .

RUN nix develop --command bash -c ' \
      export GEM_HOME="/app/.gem" \
      && export GEM_PATH="/app/.gem" \
      && export BUNDLE_PATH="/app/.gem" \
      && export BUNDLE_BIN="/app/.gem/bin" \
      && cd example \
      && bundle install --jobs 4 --without development test'

# ── 1c. Build a runtime-only nix store closure ─────────────────────
#    Only the packages needed at runtime - no gcc, make, pkg-config.
RUN mkdir -p /output/store \
    && nix-env --profile /output/runtime -iA \
         nixpkgs.ruby_3_4 \
         nixpkgs.libyaml \
         nixpkgs.openssl \
         nixpkgs.cacert \
    && cp -va $(nix-store -qR /output/runtime) /output/store

# ── 1d. Chase native-extension .so deps into the closure ───────────
#    Some gems compile C extensions that link against nix store paths
#    not captured above. Scan them and pull in their full closures.
RUN find /app/.gem -name '*.so' -exec ldd {} + 2>/dev/null \
      | grep '/nix/store' \
      | awk '{print $3}' \
      | sort -u \
      | xargs -I{} nix-store -qR {} 2>/dev/null \
      | sort -u \
      | while read p; do cp -van "$p" /output/store/ 2>/dev/null || true; done

# ── 1e. Wire up CA certificates ───────────────────────────────────
#    cacert lands in the nix store; place it where SSL_CERT_FILE expects it.
RUN mkdir -p /output/etc/ssl/certs \
    && CACERT_PATH=$(find /output/store -path '*/etc/ssl/certs/ca-bundle.crt' | head -1) \
    && if [ -n "$CACERT_PATH" ]; then \
         cp "$CACERT_PATH" /output/etc/ssl/certs/ca-bundle.crt; \
       else \
         CACERT_PATH=$(find /nix/store -maxdepth 3 -name 'ca-bundle.crt' | head -1) \
         && cp "$CACERT_PATH" /output/etc/ssl/certs/ca-bundle.crt; \
       fi

# ── 1f. Create non-root user (write directly, no adduser needed) ──
RUN echo 'caldav:x:10000:10000:caldav:/nonexistent:/bin/false' >> /etc/passwd \
    && echo 'caldav:x:10000:' >> /etc/group

# ── 1g. Prepare writable directories ──────────────────────────────
RUN mkdir -p /to_add/data /to_add/tmp \
    && chown 10000:10000 /to_add/data /to_add/tmp

# ── 1h. Stage only the runtime app files (no .git, no flake, no build cruft)
RUN mkdir -p /output/app \
    && cp -a lib/              /output/app/lib \
    && cp -a example/          /output/app/example \
    && cp -a .gem/             /output/app/.gem \
    && cp    Gemfile           /output/app/Gemfile \
    && cp    Gemfile.lock      /output/app/Gemfile.lock \
    && cp    caldav.gemspec    /output/app/caldav.gemspec \
    && cp    LICENSE           /output/app/LICENSE


# ── Stage 2: Distroless scratch image ────────────────────────────────
FROM scratch

LABEL org.opencontainers.image.title="caldav" \
      org.opencontainers.image.description="Minimal CalDAV server" \
      org.opencontainers.image.source="https://github.com/n-at-han-k/caldav"

# Nix store closure (runtime deps only)
COPY --from=build /output/store /nix/store
COPY --from=build /output/runtime/ /usr/local/

# Application files (no .git, no flake.nix, no build tooling)
COPY --from=build /output/app /app

# CA certificates
COPY --from=build /output/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-bundle.crt

# User database
COPY --from=build /etc/passwd /etc/passwd
COPY --from=build /etc/group /etc/group

# Writable directories
COPY --from=build --chown=10000:10000 /to_add/data /data
COPY --from=build --chown=10000:10000 /to_add/tmp /tmp

ENV GEM_HOME="/app/.gem" \
    GEM_PATH="/app/.gem" \
    BUNDLE_PATH="/app/.gem" \
    BUNDLE_BIN="/app/.gem/bin" \
    PATH="/app/.gem/bin:/usr/local/bin:$PATH" \
    SSL_CERT_FILE="/etc/ssl/certs/ca-bundle.crt" \
    RUBY_GC_HEAP_INIT_SLOTS=600000 \
    RUBY_GC_HEAP_FREE_SLOTS=600000 \
    RUBY_GC_HEAP_GROWTH_FACTOR=1.25

USER caldav
EXPOSE 9292
WORKDIR /app/example

CMD ["bundle", "exec", "falcon", "host"]
