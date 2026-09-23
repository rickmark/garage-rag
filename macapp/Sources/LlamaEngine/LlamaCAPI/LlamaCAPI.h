// Umbrella header that exposes the llama.cpp C API to Swift as the `LlamaCAPI` module.
//
// llama.h (and the ggml headers it includes) come from the //ext/llama_cpp cmake build's
// install prefix; the static libraries are linked into LlamaXPCService only, so neither the
// app nor the client modules carry the inference engine.
#ifndef GARAGE_LLAMA_CAPI_H
#define GARAGE_LLAMA_CAPI_H

#include "llama.h"

#endif /* GARAGE_LLAMA_CAPI_H */
