#import "ExceptionCatcher.h"

BOOL CECatchException(NS_NOESCAPE void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
            userInfo[NSLocalizedDescriptionKey] = exception.reason ?: @"Exception";
            if (exception.userInfo) {
                [userInfo addEntriesFromDictionary:exception.userInfo];
            }
            *error = [NSError errorWithDomain:exception.name code:0 userInfo:userInfo];
        }
        return NO;
    }
}
