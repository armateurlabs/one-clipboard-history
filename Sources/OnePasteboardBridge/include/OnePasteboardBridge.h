#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// NSPasteboard can raise Objective-C communication exceptions, which Swift's
/// do/catch cannot intercept. Keep the exception boundary outside Swift callers.
@interface OCHExceptionBoundary : NSObject
+ (BOOL)perform:(void (NS_NOESCAPE ^)(void))operation error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
