//
//  GaragePythonEmbed.h
//  PythonXPCService
//
//  Thin C shim around the CPython "PyConfig" embedding API
//  (https://docs.python.org/3/extending/embedding.html and
//  https://docs.python.org/3/c-api/init_config.html).
//
//  The Swift side cannot express `PyConfig` (it is a C struct with wchar_t
//  members and is not part of the stable ABI), so the isolated interpreter
//  configuration is done here and exposed through a handful of plain C
//  functions that Swift can call.
//

#ifndef GARAGE_PYTHON_EMBED_H
#define GARAGE_PYTHON_EMBED_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Options describing an isolated Python.framework environment bundled inside the app.
typedef struct GaragePythonEmbedOptions {
    /// Directory used as `PyConfig.home` (prefix and exec_prefix). Usually
    /// `site-python` in `PythonXPCService.framework`'s resources.
    const char *home;
    /// Directory containing the pure-Python standard library (`os.py`, ...).
    const char *stdlibDir;
    /// Directory containing the compiled extension modules (`lib-dynload`).
    const char *platStdlibDir;
    /// NULL-terminated list of additional `sys.path` entries (site-packages, app code, ...).
    const char *const *extraSearchPaths;
    /// Value reported as `sys.executable` / `PyConfig.program_name`. May be NULL.
    const char *programName;
    /// When true, `.pyc` files are never written (bundle is read-only / sandboxed).
    bool disableBytecodeWriting;
    /// When true, CPython does not install its own SIGINT/SIGPIPE handlers so the
    /// host process keeps full control of signal handling.
    bool skipSignalHandlers;
    /// When true, the `site` module is imported during startup.
    bool importSite;
    /// When true, the interpreter releases the GIL after initialization so that
    /// other threads may acquire it via `PyGILState_Ensure`.
    bool releaseGILAfterInit;
    /// When true, additional diagnostics are written to stderr by CPython during path configuration.
    bool verbose;
} GaragePythonEmbedOptions;

/// Result of initializing the interpreter.
typedef enum GaragePythonEmbedResult {
    GaragePythonEmbedResultOK = 0,
    GaragePythonEmbedResultAlreadyInitialized = 1,
    GaragePythonEmbedResultInvalidArgument = 2,
    GaragePythonEmbedResultConfigError = 3,
    GaragePythonEmbedResultInitError = 4,
    GaragePythonEmbedResultExit = 5,
} GaragePythonEmbedResult;

/// Returns a zeroed options struct with sensible defaults for an app-bundled interpreter.
GaragePythonEmbedOptions GaragePythonEmbedOptionsDefault(void);

/// Initializes the interpreter from an isolated `PyConfig` built from `options`.
///
/// On failure `errorBuffer` (if non-NULL) receives a NUL terminated description of
/// the failure (`PyStatus.err_msg` / `PyStatus.func` or a shim-level message).
GaragePythonEmbedResult GaragePythonEmbedInitialize(const GaragePythonEmbedOptions *options,
                                                    char *errorBuffer,
                                                    size_t errorBufferSize);

/// Returns true when `Py_IsInitialized()` is non-zero.
bool GaragePythonEmbedIsInitialized(void);

/// Finalizes the interpreter (`Py_FinalizeEx`). Returns the CPython return code (0 on success, -1 on error).
int GaragePythonEmbedFinalize(void);

/// Acquires the GIL for the calling thread. Returns an opaque token for `GaragePythonEmbedReleaseGIL`.
int GaragePythonEmbedAcquireGIL(void);

/// Releases the GIL previously acquired with `GaragePythonEmbedAcquireGIL`.
void GaragePythonEmbedReleaseGIL(int token);

/// Runs `source` as a Python script in `__main__`. Returns 0 on success, -1 on error
/// (in which case the exception has already been printed to stderr).
int GaragePythonEmbedRunSimpleString(const char *source);

/// Returns the compile-time CPython version string (`PY_VERSION`).
const char *GaragePythonEmbedCompiledVersion(void);

/// Returns the runtime version string (`Py_GetVersion()`).
const char *GaragePythonEmbedRuntimeVersion(void);

#ifdef __cplusplus
}
#endif

#endif /* GARAGE_PYTHON_EMBED_H */
