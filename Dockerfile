FROM julia:1.13

WORKDIR /app

# Install dependencies before copying configuration, so editing a config file
# reuses this layer.
COPY soleil/Project.toml soleil/Manifest.toml ./
COPY soleil/Solar/ ./Solar/
COPY soleil/Soleil/ ./Soleil/
RUN julia --project=/app -e 'using Pkg; Pkg.instantiate()'

COPY soleil/config.toml soleil/config-docker-*.toml ./

# The file and SQLite backends keep state here; mount a volume to keep it.
VOLUME ["/app/state"]
EXPOSE 9001

CMD ["julia", "--project=/app", "-e", "using Soleil; Soleil.run()"]
