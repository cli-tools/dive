# dive.sh

A Docker Compose wrapper for interactive container development sessions.

> **Note:** Named `dive.sh` to avoid collision with [wagoodman/dive](https://github.com/wagoodman/dive), a tool for exploring Docker image layers.

## Requirements

- docker
- docker compose plugin
- yq

## Usage

```bash
dive.sh [options] [service] [-- command...]
```

### Options

- `-C <path>` - Change to directory before doing anything
- `-n, --no-build` - Skip building the container
- `-s, --shell <path>` - Use specified shell (default: bash)
- `-h, --help` - Show help message
- `--` - Pass remaining arguments as command to execute

### Examples

```bash
# Start interactive session (auto-detects service)
dive.sh

# Start with specific service
dive.sh myservice

# Use fish shell
dive.sh -s fish

# Skip build step
dive.sh -n

# Run a command instead of interactive shell
dive.sh -- npm test
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

## Testing

The `test/` directory contains a minimal compose project for validating shell
init across bash, zsh, and fish. The test uses `script(1)` to simulate a TTY
(required by `docker compose exec -it`).

### Setup

```bash
cd test
docker compose build -q
```

### test/Dockerfile

```dockerfile
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash zsh fish \
    && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /opt/myapp/bin && printf '%s\n' \
    'export MYAPP_HOME=/opt/myapp' \
    'export PATH="$MYAPP_HOME/bin:$PATH"' \
    > /opt/myapp/env.sh
CMD ["sleep", "infinity"]
```

### test/compose.yaml

```yaml
services:
  testbox:
    build: .
    command: sleep infinity

x-dive:
  shell: bash
  init: "source /opt/myapp/env.sh"
```

### Validate

Run from the `test/` directory. Each test launches an interactive shell via
`script -qec`, sends commands through stdin, then greps the output for
expected values after stripping ANSI escape sequences.

```bash
strip_ansi() {
  sed 's/\x1b\[[^m]*m//g; s/\x1b\[[^a-zA-Z]*[a-zA-Z]//g; s/\r//g' "$1"
}

# Command mode — init env available in all shells
for sh in bash zsh fish; do
  result=$(dive.sh -n -s "$sh" -- echo "MYAPP=\$MYAPP_HOME")
  echo "$sh cmd: $result"
  [[ "$result" == *"MYAPP=/opt/myapp"* ]] || { echo "FAIL: $sh cmd"; exit 1; }
done

# Interactive mode — prompt and init env present
script -qec 'dive.sh -n -s bash' /tmp/t-bash.txt <<< $'echo "PS1=[$PS1] MYAPP=[$MYAPP_HOME]"\nexit'
out=$(strip_ansi /tmp/t-bash.txt)
echo "$out" | grep -q 'PS1=\[.*\\u@\\h' || { echo "FAIL: bash PS1"; exit 1; }
echo "$out" | grep -q 'MYAPP=\[/opt/myapp\]' || { echo "FAIL: bash MYAPP"; exit 1; }

script -qec 'dive.sh -n -s zsh' /tmp/t-zsh.txt <<< $'echo "PROMPT=[$PROMPT] MYAPP=[$MYAPP_HOME]"\nexit'
out=$(strip_ansi /tmp/t-zsh.txt)
echo "$out" | grep -q 'PROMPT=\[%m%# \]' || { echo "FAIL: zsh PROMPT"; exit 1; }
echo "$out" | grep -q 'MYAPP=\[/opt/myapp\]' || { echo "FAIL: zsh MYAPP"; exit 1; }

script -qec 'dive.sh -n -s fish' /tmp/t-fish.txt <<< $'echo "MYAPP=[$MYAPP_HOME]"\nexit'
out=$(strip_ansi /tmp/t-fish.txt)
echo "$out" | grep -q 'MYAPP=\[/opt/myapp\]' || { echo "FAIL: fish MYAPP"; exit 1; }

echo "ALL PASSED"
```

### Cleanup

```bash
docker compose down
```

## License

BSD Zero Clause License (0BSD) - See source for details.
