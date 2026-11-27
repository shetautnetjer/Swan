`tiny-ts.swan.db` is a map of `fixtures/tiny-ts` made by the Goose program (`swan map`, Swan `419b3be`), for
`tests/serve.rs`: the Rust `swan serve` is asked the questions `tests/check/mcp_suite.goose` asks of the Goose one.
The test copies it and points its `root` at this checkout's `fixtures/tiny-ts`. Remake it with
`swan map fixtures/tiny-ts <dir>` when the map's schema changes.
