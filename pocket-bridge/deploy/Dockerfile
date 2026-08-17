# syntax=docker/dockerfile:1

# Build context is the pocket-bridge/ directory:
#   docker build -f deploy/Dockerfile .
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Restore against the manifests alone so the layer cache survives source-only edits.
COPY global.json Directory.Build.props Directory.Packages.props PocketBridge.sln ./
COPY src/PocketBridge.Core/PocketBridge.Core.csproj src/PocketBridge.Core/
COPY src/PocketBridge.Infrastructure/PocketBridge.Infrastructure.csproj src/PocketBridge.Infrastructure/
COPY src/PocketBridge.Host/PocketBridge.Host.csproj src/PocketBridge.Host/
COPY tests/PocketBridge.Core.Tests/PocketBridge.Core.Tests.csproj tests/PocketBridge.Core.Tests/
RUN dotnet restore PocketBridge.sln

COPY . .
RUN dotnet publish src/PocketBridge.Host/PocketBridge.Host.csproj \
    -c Release \
    -o /app/publish \
    --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app

# Provided by the base image; runs as a non-root uid.
USER $APP_UID

# Only consulted in `serve` mode — the `sync` entrypoint never binds a port.
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

COPY --from=build /app/publish .

# Defaults to `sync`, the CronJob entrypoint. Override with `serve` for the
# long-lived mode:  args: ["serve"]
ENTRYPOINT ["dotnet", "PocketBridge.Host.dll"]
CMD ["sync"]
