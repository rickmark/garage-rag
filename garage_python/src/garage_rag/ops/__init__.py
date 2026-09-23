"""Operations the CLI and the gRPC service share.

Each function does one thing the app can ask for (register a source, backfill a
model, install the MCP server into a client), returns a dataclass describing
what happened, and raises LookupError/ValueError/FileExistsError for the
caller to present. ``cli.py`` renders the result for a terminal;
``service/server.py`` translates it to protobuf. Neither re-implements the work.
"""
