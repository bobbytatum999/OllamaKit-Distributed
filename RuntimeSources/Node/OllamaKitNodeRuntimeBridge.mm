#import <Foundation/Foundation.h>
#import "NodeMobile.h"
#include <vector>
#import "OllamaKitNodeRuntimeBridge.h"

static NSObject *OllamaKitNodeLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
    });
    return lock;
}

static char *OllamaKitNodeJSONString(NSDictionary *payload) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSString *string = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{\"success\":false,\"error\":\"json_encoding_failed\"}";
    return strdup(string.UTF8String);
}

static NSDictionary *OllamaKitNodeFailure(NSString *message) {
    return @{
        @"success": @NO,
        @"stdout": @"",
        @"stderr": @"",
        @"exitCode": @1,
        @"durationMs": @0,
        @"result": [NSNull null],
        @"artifacts": @[],
        @"error": message ?: @"Unknown embedded Node failure."
    };
}

char *OllamaKitNodeRunJSON(
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
            URLByAppendingPathComponent:@"OllamaKitNodeRuntime.framework"
            isDirectory:YES];
        if (![[NSFileManager defaultManager] fileExistsAtPath:frameworkURL.path]) {
            frameworkURL = [[NSBundle mainBundle].bundleURL
                URLByAppendingPathComponent:@"Frameworks/OllamaKitNodeRuntime.framework"
                isDirectory:YES];
        }
        NSString *frameworkRoot = frameworkURL.path;
        NSString *temporaryDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];

        NSError *directoryError = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:temporaryDirectory withIntermediateDirectories:YES attributes:nil error:&directoryError];
        if (directoryError) {
            return OllamaKitNodeJSONString(OllamaKitNodeFailure(directoryError.localizedDescription));
        }

        NSString *scriptPath = [temporaryDirectory stringByAppendingPathComponent:@"script.js"];
        NSString *inputPath = [temporaryDirectory stringByAppendingPathComponent:@"input.json"];
        NSString *resultPath = [temporaryDirectory stringByAppendingPathComponent:@"result.json"];

        if (![scriptString writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:&directoryError] ||
            ![inputString writeToFile:inputPath atomically:YES encoding:NSUTF8StringEncoding error:&directoryError]) {
            [[NSFileManager defaultManager] removeItemAtPath:temporaryDirectory error:nil];
            return OllamaKitNodeJSONString(OllamaKitNodeFailure(directoryError.localizedDescription));
        }

        NSString *allowlistPath = [frameworkRoot stringByAppendingPathComponent:@"Resources/OllamaKitNode/native-addon-allowlist.json"];
        NSString *bootstrapPath = [frameworkRoot stringByAppendingPathComponent:@"Resources/OllamaKitNode/bootstrap.js"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:bootstrapPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:temporaryDirectory error:nil];
            return OllamaKitNodeJSONString(OllamaKitNodeFailure(@"The embedded Node bootstrap resource is missing."));
        }

        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithArray:@[
            @"node",
            bootstrapPath,
            scriptPath,
            inputPath,
            resultPath,
            workspaceRoot
        ]];

        NSMutableArray<NSMutableData *> *argumentStorage = [NSMutableArray arrayWithCapacity:arguments.count];
        std::vector<char *> argv;
        argv.reserve(arguments.count);

        for (NSString *argument in arguments) {
            NSData *data = [argument dataUsingEncoding:NSUTF8StringEncoding];
            NSMutableData *mutableData = [NSMutableData dataWithData:data];
            [mutableData appendBytes:"\0" length:1];
            [argumentStorage addObject:mutableData];
            argv.push_back((char *)mutableData.mutableBytes);
        }

        setenv("OLLAMAKIT_SCRIPT_PATH", scriptPath.UTF8String, 1);
        setenv("OLLAMAKIT_INPUT_PATH", inputPath.UTF8String, 1);
        setenv("OLLAMAKIT_RESULT_PATH", resultPath.UTF8String, 1);
        setenv("OLLAMAKIT_WORKSPACE_ROOT", workspaceRoot.UTF8String, 1);
        setenv("OLLAMAKIT_NODE_ALLOWLIST_PATH", allowlistPath.UTF8String, 1);

        NSDictionary *payload = nil;
        @synchronized (OllamaKitNodeLock()) {
            int exitCode = node_start((int)argv.size(), argv.data());
            NSData *resultData = [NSData dataWithContentsOfFile:resultPath];
            if (resultData != nil) {
                NSMutableDictionary *decoded = [[NSJSONSerialization JSONObjectWithData:resultData options:NSJSONReadingMutableContainers error:nil] mutableCopy];
                if (decoded != nil) {
                    decoded[@"exitCode"] = @(exitCode);
                    decoded[@"durationMs"] = @((NSInteger)([[NSDate date] timeIntervalSinceDate:startedAt] * 1000.0));
                    payload = decoded;
                }
            }

            if (payload == nil) {
                payload = [OllamaKitNodeFailure(@"The embedded Node runtime finished without producing a result payload.") mutableCopy];
                [(NSMutableDictionary *)payload setObject:@(exitCode) forKey:@"exitCode"];
                [(NSMutableDictionary *)payload setObject:@((NSInteger)([[NSDate date] timeIntervalSinceDate:startedAt] * 1000.0)) forKey:@"durationMs"];
            }
        }

        [[NSFileManager defaultManager] removeItemAtPath:temporaryDirectory error:nil];
        return OllamaKitNodeJSONString(payload ?: OllamaKitNodeFailure(@"Unknown embedded Node failure."));
    }
}
