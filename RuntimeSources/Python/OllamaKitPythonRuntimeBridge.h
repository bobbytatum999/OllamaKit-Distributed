#pragma once

#ifdef __cplusplus
extern "C" {
#endif

char *OllamaKitPythonRunJSON(
    const char *script,
    const char *input_json,
    const char *workspace_root
);

#ifdef __cplusplus
}
#endif
