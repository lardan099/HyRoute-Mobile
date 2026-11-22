#import "HyRouteBridge.h"
#import <HyRouteCore/HyRouteCore.h>

NSString * _Nullable HyRoutePreview(NSString *input, BOOL fromURL) {
    NSError *error = nil;
    NSString *preview = MobilePreviewSubscription(input, fromURL, &error);
    return error == nil ? preview : nil;
}

BOOL HyRouteValidate(NSString *configuration, NSString *selectedServer) {
    NSError *error = nil;
    return MobileNewRouter(configuration, selectedServer, &error) != nil && error == nil;
}
