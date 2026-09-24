import GarageLauncher

// `Garage.app/Contents/MacOS/garage-mcp [--config PATH]`: the stdio MCP server that
// Claude Desktop / Claude Code spawn. Starts the app (hidden) when its database is
// not running, and reads the database password from the shared data folder.
Launcher.run(.mcp)
