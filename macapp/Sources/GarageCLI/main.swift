import GarageLauncher

// `Garage.app/Contents/MacOS/garage`: the full CLI on the bundled interpreter. Starts
// the app (hidden) when a command needs its database and it is not running.
Launcher.run(.cli)
