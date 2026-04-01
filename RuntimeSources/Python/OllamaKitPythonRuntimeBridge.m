#import <Foundation/Foundation.h>
#import "Python.h"
#import "OllamaKitPythonRuntimeBridge.h"

static NSObject *OllamaKitPythonLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
    });
    return lock;
}

static char *OllamaKitPythonJSONString(NSDictionary *payload) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSString *string = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{\"success\":false,\"error\":\"json_encoding_failed\"}";
    return strdup(string.UTF8String);
}

static NSDictionary *OllamaKitPythonFailure(NSString *message) {
    return @{
        @"success": @NO,
        @"stdout": @"",
        @"stderr": @"",
        @"exitCode": @1,
        @"durationMs": @0,
        @"result": [NSNull null],
        @"artifacts": @[],
        @"error": message ?: @"Unknown embedded Python error."
    };
}

static NSString *OllamaKitPythonInitialize(NSString *bundleRoot) {
    NSString *homeRoot = [bundleRoot stringByAppendingPathComponent:@"Resources/OllamaKitPython/Home"];
    NSString *libRoot = [homeRoot stringByAppendingPathComponent:@"lib"];
    NSString *zipPath = [libRoot stringByAppendingPathComponent:@"python3.13.zip"];
    NSString *stdlibPath = [libRoot stringByAppendingPathComponent:@"python3.13"];
    NSString *dynloadPath = [stdlibPath stringByAppendingPathComponent:@"lib-dynload"];
    wchar_t *wideHome = Py_DecodeLocale(homeRoot.UTF8String, NULL);
    wchar_t *wideZip = Py_DecodeLocale(zipPath.UTF8String, NULL);
    wchar_t *wideStdlib = Py_DecodeLocale(stdlibPath.UTF8String, NULL);
    wchar_t *wideDynload = Py_DecodeLocale(dynloadPath.UTF8String, NULL);
    if (wideHome == NULL || wideZip == NULL || wideStdlib == NULL || wideDynload == NULL) {
        if (wideHome) {
            PyMem_RawFree(wideHome);
        }
        if (wideZip) {
            PyMem_RawFree(wideZip);
        }
        if (wideStdlib) {
            PyMem_RawFree(wideStdlib);
        }
        if (wideDynload) {
            PyMem_RawFree(wideDynload);
        }
        return @"Failed to prepare the embedded Python runtime paths.";
    }

    PyConfig config;
    PyConfig_InitPythonConfig(&config);
    config.use_environment = 0;
    config.install_signal_handlers = 0;
    config.module_search_paths_set = 1;
    config.write_bytecode = 0;

    PyStatus status = PyConfig_SetBytesString(&config, &config.program_name, "ollamakit-python");
    if (!PyStatus_Exception(status)) {
        status = PyConfig_SetString(&config, &config.home, wideHome);
    }
    if (!PyStatus_Exception(status)) {
        status = PyWideStringList_Append(&config.module_search_paths, wideZip);
    }
    if (!PyStatus_Exception(status)) {
        status = PyWideStringList_Append(&config.module_search_paths, wideStdlib);
    }
    if (!PyStatus_Exception(status)) {
        status = PyWideStringList_Append(&config.module_search_paths, wideDynload);
    }
    if (!PyStatus_Exception(status)) {
        status = Py_InitializeFromConfig(&config);
    }

    NSString *failureMessage = nil;
    if (PyStatus_Exception(status)) {
        failureMessage = status.err_msg != NULL
            ? [NSString stringWithUTF8String:status.err_msg]
            : @"Failed to initialize the embedded Python runtime.";
    }

    PyConfig_Clear(&config);
    PyMem_RawFree(wideHome);
    PyMem_RawFree(wideZip);
    PyMem_RawFree(wideStdlib);
    PyMem_RawFree(wideDynload);
    return failureMessage;
}

char *OllamaKitPythonRunJSON(
    const char *script,
    const char *input_json,
    const char *workspace_root
) {
    @autoreleasepool {
        NSString *scriptString = script ? [NSString stringWithUTF8String:script] : @"";
        NSString *inputString = input_json ? [NSString stringWithUTF8String:input_json] : @"null";
        NSString *workspaceRoot = workspace_root ? [NSString stringWithUTF8String:workspace_root] : @"";
        NSDate *startedAt = [NSDate date];

        NSURL *frameworkURL = [[NSBundle mainBundle].privateFrameworksURL
            URLByAppendingPathComponent:@"OllamaKitPythonRuntime.framework"
            isDirectory:YES];
        if (![[NSFileManager defaultManager] fileExistsAtPath:frameworkURL.path]) {
            frameworkURL = [[NSBundle mainBundle].bundleURL
                URLByAppendingPathComponent:@"Frameworks/OllamaKitPythonRuntime.framework"
                isDirectory:YES];
        }
        NSString *frameworkRoot = frameworkURL.path;
        NSString *bootstrapPath = [frameworkRoot stringByAppendingPathComponent:@"Resources/OllamaKitPython/bootstrap.py"];
        NSString *allowlistPath = [frameworkRoot stringByAppendingPathComponent:@"Resources/OllamaKitPython/native-extension-allowlist.json"];
        NSString *temporaryDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];

        if (![[NSFileManager defaultManager] fileExistsAtPath:bootstrapPath]) {
            return OllamaKitPythonJSONString(OllamaKitPythonFailure(@"The embedded Python bootstrap resource is missing."));
        }

        NSError *directoryError = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:temporaryDirectory withIntermediateDirectories:YES attributes:nil error:&directoryError];
        if (directoryError) {
            return OllamaKitPythonJSONString(OllamaKitPythonFailure(directoryError.localizedDescription));
        }

        NSString *scriptPath = [temporaryDirectory stringByAppendingPathComponent:@"script.py"];
        NSString *inputPath = [temporaryDirectory stringByAppendingPathComponent:@"input.json"];
        NSString *resultPath = [temporaryDirectory stringByAppendingPathComponent:@"result.json"];

        if (![scriptString writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:&directoryError] ||
            ![inputString writeToFile:inputPath atomically:YES encoding:NSUTF8StringEncoding error:&directoryError]) {
            [[NSFileManager defaultManager] removeItemAtPath:temporaryDirectory error:nil];
            return OllamaKitPythonJSONString(OllamaKitPythonFailure(directoryError.localizedDescription));
        }

        NSDictionary *payload = nil;

        @synchronized (OllamaKitPythonLock()) {
            if (!Py_IsInitialized()) {
                NSString *initializeError = OllamaKitPythonInitialize(frameworkRoot);
                if (initializeError != nil) {
                    [[NSFileManager defaultManager] removeItemAtPath:temporaryDirectory error:nil];
                    return OllamaKitPythonJSONString(OllamaKitPythonFailure(initializeError));
                }
            }

            setenv("OLLAMAKIT_SCRIPT_PATH", scriptPath.UTF8String, 1);
            setenv("OLLAMAKIT_INPUT_PATH", inputPath.UTF8String, 1);
            setenv("OLLAMAKIT_RESULT_PATH", resultPath.UTF8String, 1);
            setenv("OLLAMAKIT_WORKSPACE_ROOT", workspaceRoot.UTF8String, 1);
            setenv("OLLAMAKIT_PYTHON_ALLOWLIST_PATH", allowlistPath.UTF8String, 1);

            NSString *bootstrapSource = [NSString stringWithContentsOfFile:bootstrapPath encoding:NSUTF8StringEncoding error:nil];
            int runResult = bootstrapSource != nil ? PyRun_SimpleString(bootstrapSource.UTF8String) : -1;
            NSData *resultData = [NSData dataWithContentsOfFile:resultPath];

            if (resultData != nil) {
                NSMutableDictionary *decoded = [[NSJSONSerialization JSONObjectWithData:resultData options:NSJSONReadingMutableContainers error:nil] mutableCopy];
                if (decoded == nil) {
                    payload = OllamaKitPythonFailure(@"The embedded Python runtime returned invalid JSON.");
                } else {
                    decoded[@"durationMs"] = @((NSInteger)([[NSDate date] timeIntervalSinceDate:startedAt] * 1000.0));
                    payload = decoded;
                }
            } else if (runResult != 0) {
                payload = OllamaKitPythonFailure(@"The embedded Python runtime failed before it could produce a result payload.");
            } else {
                payload = OllamaKitPythonFailure(@"The embedded Python runtime finished without producing a result payload.");
            }
        }

        [[NSFileManager defaultManager] removeItemAtPath:temporaryDirectory error:nil];
        return OllamaKitPythonJSONString(payload ?: OllamaKitPythonFailure(@"Unknown embedded Python failure."));
    }
}
