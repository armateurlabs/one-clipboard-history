#import "MPasteboardBridge.h"

@implementation MCMExceptionBoundary
+ (BOOL)perform:(void (NS_NOESCAPE ^)(void))operation error:(NSError * _Nullable * _Nullable)error {
    @try {
        operation();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            // Provider exceptions can contain copied data in their reason.
            // Never include that reason in user-visible errors or logs.
            *error = [NSError errorWithDomain:@"app.mcm.pasteboard.communication"
                                        code:1
                                    userInfo:@{NSLocalizedDescriptionKey:
                                        @"Clipboard communication was interrupted. Capture will be retried."}];
        }
        return NO;
    }
}
@end
