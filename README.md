# GitNexus Gateway (Dockerized)

A containerized Model Context Protocol (MCP) server for [GitNexus](https://github.com/gitnexus/mcp), providing an HTTP/SSE interface with API Key authentication and CORS support. This image bridges standard I/O (stdio) MCP communications into a robust, network-accessible server using `supergateway` and `HAProxy`.

It is optimized to operate on local repositories mounted inside the container.

## Project Origin

This project was independently implemented after reviewing the public Docker Hub package `mekayelanik/gitnexus-mcp` as a reference point for packaging direction and deployment ergonomics.

The goal here is to provide a transparent, auditable repository for a GitNexus gateway image with explicit Docker, auth, and CORS behavior.

## Features

- **Protocol Bridge:** Converts native `stdio` MCP traffic to `HTTP/SSE/WebSocket` via Supergateway.
- **Authentication:** Built-in API Key enforcement (`Authorization: Bearer <API_KEY>`) handled by HAProxy.
- **CORS Support:** Integrated Cross-Origin Resource Sharing for web-based AI clients.
- **Multi-Architecture:** Automatically builds and runs on `amd64` (x86_64) and `arm64` (Apple Silicon / ARM).
- **Auto-Initialization:** Automatically detects and analyzes codebases mounted in the `/data` directory on startup.

## Quick Start

Run the server with Docker, mounting your source code directory and supplying an API Key for security:

```bash
docker run -d \
  --name gitnexus-gateway \
  -p 8010:8010 \
  -e API_KEY="your-secure-api-key" \
  -e CORS="*" \
  -v /path/to/your/local/repos:/data \
  -v gitnexus-registry:/home/node/.gitnexus \
  your-dockerhub-username/gitnexus-gateway:latest
```

## Docker Compose

Save this as `docker-compose.yml` and run `docker compose up -d`:

```yaml
services:
  gitnexus-gateway:
    image: your-dockerhub-username/gitnexus-gateway:latest
    container_name: gitnexus-gateway
    restart: unless-stopped
    ports:
      - "8010:8010"
    volumes:
      # Mount your repositories here
      - /path/to/your/repos:/data:rw
      # Persist the GitNexus graph/index registry
      - gitnexus-registry:/home/node/.gitnexus
    environment:
      - PORT=8010
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Taipei
      
      # Security (Required for public exposure)
      - API_KEY=your-secure-api-key
      - CORS=*
      
      # Behavior
      - PROTOCOL=SHTTP
      - DATA_DIR=/data
      - ANALYZE_FORCE=false
      - ANALYZE_VERBOSE=true

volumes:
  gitnexus-registry:
    driver: local
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8010` | The port HAProxy listens on. |
| `API_KEY` | (None) | **Important:** If set, restricts access to clients providing this Bearer token. |
| `CORS` | (None) | Allowed CORS origins (e.g., `*` or `http://localhost:3000`). |
| `DATA_DIR` | `/data` | Where the container looks for repositories to analyze. |
| `PROTOCOL` | `SHTTP` | Supergateway protocol mapping mode (usually `SHTTP` or `SSE`). |
| `ANALYZE_FORCE` | `false` | If `true`, forces re-analysis of all mounted repositories on boot. |
| `PUID` / `PGID`| `1000` / `1000` | Adjusts the `node` user ID/group ID to match host permissions. |

## Volumes

- `/data`: Bind-mount your project repositories here. Each subfolder will be detected and indexed by GitNexus.
- `/home/node/.gitnexus`: Volume for storing the indexed graph databases and cache. **Must be persisted** to avoid re-indexing large projects on every restart.

## Connecting from MCP Clients

Once the server is running, you can connect your preferred AI IDE or desktop app using the Model Context Protocol.

### Cursor / Windsurf / AppFlowy
Configure the server as an **SSE** or **HTTP** MCP server depending on the tool's UI.
* **URL:** `http://localhost:8010` (or `http://localhost:8010/message` depending on the client).
* **Headers:** Add `Authorization: Bearer your-secure-api-key`.

### Connecting via StdIO (Claude Desktop fallback)
If your client *requires* `stdio`, you would typically run the base `gitnexus` command natively, but you can also bridge a running container using `docker exec`:

```json
{
  "mcpServers": {
    "gitnexus": {
      "command": "docker",
      "args": ["exec", "-i", "gitnexus-gateway", "gosu", "node", "gitnexus", "mcp"]
    }
  }
}
```

## License & Disclaimer

This Dockerfile/Image setup incorporates upstream components that are intended for **non-commercial** use (per GitNexus licensing). Ensure your usage complies with upstream requirements before deploying in enterprise or production environments.
