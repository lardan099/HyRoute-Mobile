#import "HyRouteBridge.h"
#import <HyRouteCore/HyRouteCore.h>

NSString * _Nullable HyRouteStateView(NSString *state) {
    NSError *error = nil;
    NSString *view = MobileClientStateView(state, &error);
    return error == nil ? view : nil;
}

NSString * _Nullable HyRouteAddSubscription(NSString *state, NSString *input, BOOL fromURL) {
    NSError *error = nil;
    NSString *updated = MobileAddClientSubscription(state, input, fromURL, &error);
    return error == nil ? updated : nil;
}

NSString * _Nullable HyRouteSaveSettings(NSString *state, NSString *settings) {
    NSError *error = nil;
    NSString *updated = MobileSaveClientSettings(state, settings, NO, &error);
    return error == nil ? updated : nil;
}

void HyRouteConfigureGeo(NSString *directory) {
    MobileConfigureGeo(directory);
}

NSString * _Nullable HyRouteGeoTags(void) {
    NSError *error = nil;
    NSString *tags = MobileGeoTags(&error);
    return error == nil ? tags : nil;
}

BOOL HyRouteUpdateGeo(void) {
    NSError *error = nil;
    return MobileUpdateGeo(&error);
}
