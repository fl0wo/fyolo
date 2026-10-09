# fyolo

My personal, customized build of [termio](https://termio.sh): a terminal-first
agentic development environment for macOS. fyolo is a fork of
[termio-sh/termio](https://github.com/termio-sh/termio), tuned to how I work and
extended with my own custom connectors.

It is not a product and is not for sale. It's open source because termio is.

## What's different from termio

- Renamed throughout to fyolo, so it installs and runs beside termio without
  sharing state, sockets, or settings.
- Dark appearance and the bundled **FLO** theme (IR Black on pure black) are the
  defaults.
- The sidebar takes the theme's background, so it sits flush with the terminal.
- Custom connectors.

For what the app does and how it works, see
[termio's README](https://github.com/termio-sh/termio#readme) and the [docs](docs/).

## Build

Requires Xcode 26, Rust, and Zig 0.16 (`brew install zig@0.16`).

```sh
PATH="$(brew --prefix zig@0.16)/bin:$PATH" FYOLO_CHANNEL=dev ./scripts/build-app.sh
open ./fyolo-dev.app
```

## License

[MIT](LICENSE), like termio. The original copyright notice is kept in `LICENSE`.
