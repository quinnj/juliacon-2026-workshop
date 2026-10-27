# Compile Soleil into a native executable with `juliac --trim=safe`, then ship
# it in a from-scratch image holding only that executable, its bundled
# libraries, and the system libraries they load.
ARG JULIA_VERSION=1.14.0-alpha2

FROM debian:bookworm-slim AS build
ARG JULIA_VERSION
ARG TARGETARCH

# juliac links the executable with the system C compiler.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*
RUN case "$TARGETARCH" in arm64) dir=aarch64 file=aarch64 ;; *) dir=x64 file=x86_64 ;; esac \
    && series=$(echo "$JULIA_VERSION" | cut -d. -f1,2) \
    && mkdir /opt/julia \
    && curl -fsSL "https://julialang-s3.julialang.org/bin/linux/$dir/$series/julia-$JULIA_VERSION-linux-$file.tar.gz" \
        | tar -xz -C /opt/julia --strip-components=1
ENV PATH=/opt/julia/bin:/root/.julia/bin:$PATH
RUN julia -e 'using Pkg; Pkg.Apps.add(name="JuliaC", version="0.3.12")'

# Install dependencies before copying the source, so source edits reuse this layer.
WORKDIR /app
COPY soleil/Project.toml soleil/Manifest.toml ./
COPY soleil/Solar/Project.toml ./Solar/
COPY soleil/Soleil/Project.toml ./Soleil/
RUN mkdir -p Solar/src Soleil/src && touch Solar/src/Solar.jl Soleil/src/Soleil.jl \
    && JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=/app -e 'using Pkg; Pkg.instantiate()'

COPY soleil/Solar/ ./Solar/
COPY soleil/Soleil/ ./Soleil/
COPY trim/main.jl ./
RUN juliac --output-exe soleil --bundle /build --project /app --trim=safe --experimental main.jl \
    && strip --strip-unneeded /build/bin/soleil

# Gather the executable's bundle and the system libraries it and its bundled
# libraries link against.
RUN mkdir -p /runtime/app /runtime/tmp && chmod 1777 /runtime/tmp && cp -a /build/. /runtime/app/ \
    && find /runtime/app -type f \( -name soleil -o -name '*.so*' \) -exec ldd {} + 2>/dev/null \
        | awk '$3 ~ /^\// { print $3 } $1 ~ /^\// { print $1 }' | grep -E '^/(lib|usr/lib)/' | sort -u \
        | xargs -I{} cp -L --parents {} /runtime

FROM scratch
COPY --from=build /runtime/ /
# Without a UTF-8 locale, Julia falls back to ASCII and says so at startup.
COPY --from=build /usr/lib/locale/C.utf8 /usr/lib/locale/C.utf8
ENV LANG=C.UTF-8
COPY soleil/config.toml soleil/config-docker.toml /app/
WORKDIR /app
VOLUME ["/app/state"]
EXPOSE 9001
ENTRYPOINT ["/app/bin/soleil"]
