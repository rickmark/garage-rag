import GarageLauncher

// `Garage.app/Contents/Helpers/garage-mcp.app/Contents/MacOS/garage-mcp [--config PATH]`,
// reached through `Garage.app/Contents/MacOS/garage-mcp` (a link to the forwarder in
// Resources/launchers): the stdio MCP server that Claude Desktop / Claude Code spawn. Starts
// the app (hidden) when its database is not running, and reads the database password from
// the Keychain.
Launcher.run(.mcp)
