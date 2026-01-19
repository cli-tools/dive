# dive

A Docker Compose wrapper for interactive container development sessions.

## Requirements

- docker
- docker compose plugin
- yq

## Usage

```bash
dive [options] [service] [-- command...]
```

### Options

- `-n, --no-build` - Skip building the container
- `-s, --shell <path>` - Use specified shell (default: bash)
- `-h, --help` - Show help message
- `--` - Pass remaining arguments as command to execute

### Examples

```bash
# Start interactive session (auto-detects service)
dive

# Start with specific service
dive myservice

# Use fish shell
dive -s fish

# Skip build step
dive -n

# Run a command instead of interactive shell
dive -- npm test
```

## Compose Extensions

Dive uses the `x-dive` extension in your compose file. Works with `compose.yaml`, `compose.yml`, `docker-compose.yaml`, `docker-compose.yml`, or any file specified via `COMPOSE_FILE`.

```yaml
x-dive:
  service: app
  shell: fish
  init: source /app/.venv/bin/activate
  env:
    CONTAINER_NAME: "{{.Service}}"
    PROJECT: "{{.Project}}"
  mounts:
    - fish
    - $HOME/.gitconfig:/root/.gitconfig
```

### Options

| Key | Description |
|-----|-------------|
| `service` | Default service when multiple exist |
| `shell` | Shell path or name (default: bash) |
| `init` | Commands to run on container entry |
| `env` | Environment variables |
| `mounts` | Host files/binaries to mount |

### Template Variables

Values in `env`, `mounts`, and `init` support Go-like `text/template` syntax:

| Variable | Description |
|----------|-------------|
| `{{.Service}}` | The service name |
| `{{.Project}}` | Compose project name (from `name:` or directory) |
| `{{.Shell}}` | The selected shell |

### Mounts

```yaml
x-dive:
  mounts:
    # Auto-detect binary on host (mounts to /usr/local/bin/<name>:ro)
    - fish
    - nvim

    # Explicit path (source:target[:mode], defaults to ro)
    - /home/user/.gitconfig:/root/.gitconfig
    - $HOME/.ssh:/root/.ssh:rw

    # Object form for binary with custom target
    - binary: fish
      target: /usr/local/bin/fish
      mode: ro

    # Object form for explicit source
    - source: $HOME/.config/nvim
      target: /root/.config/nvim
      mode: rw
```

Mount types:
- **Simple string** (no `/` or `:`): Auto-detects binary via `type -p` and mounts read-only to `/usr/local/bin/`
- **Path string** (`source:target[:mode]`): Standard docker volume syntax with environment variable expansion. Defaults to read-only.
- **Object with `binary`**: Auto-detect binary with optional custom target and mode (default: ro)
- **Object with `source`**: Explicit source path with target and mode (default: ro)

Mounts are silently skipped if the source doesn't exist.

## User Configuration

Create `~/.config/dive/config.yaml` for personal defaults that apply to all projects.

User config uses the same keys (without `x-dive:` wrapper):

```yaml
shell: fish
service: app
init: source ~/.bashrc
env:
  CONTAINER_NAME: "{{.Service}}"
  PROJECT: "{{.Project}}"
mounts:
  - fish
  - $HOME/.gitconfig:/root/.gitconfig
```

### Config Priority

Settings are loaded in this order (later overrides earlier):

1. **Compose file** - Project defaults (`x-dive:` extension)
2. **~/.config/dive/config.yaml** - User preferences (respects `$XDG_CONFIG_HOME`)
3. **CLI arguments** - Immediate overrides

Mounts and env vars from all sources are merged. Other settings are overridden.

## License

BSD Zero Clause License (0BSD) - See source for details.
