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

NSString * _Nullable HyRouteRefreshSubscription(NSString *state, NSString *subscriptionID) {
    NSError *error = nil;
    NSString *updated = MobileRefreshClientSubscription(state, subscriptionID, &error);
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

NSObject * _Nullable HyRoutePrepareVPN(NSString *state, NSString *geoDirectory, NSString *journal) {
    MobileConfigureGeo(geoDirectory);
    NSError *error = nil;
    MobileVPNPlan *plan = MobileNewVPNPlan(state, NO, &error);
    if (plan == nil) {
        MobileRecordVPNEvent(journal, @"vpn_plan_error");
        return nil;
    }
    MobileVPNPrepared *prepared = [plan prepare:&error];
    if (prepared == nil) MobileRecordVPNEvent(journal, @"vpn_prepare_error");
    return prepared;
}

NSObject * _Nullable HyRouteStartVPN(NSObject *prepared, int32_t fd) {
    NSError *error = nil;
    return [(MobileVPNPrepared *)prepared start:fd platformImpl:nil error:&error];
}

void HyRouteStopVPN(NSObject *session) {
    [(MobileVPNSession *)session stop];
}

void HyRouteRecordVPNEvent(NSString *path, NSString *event) {
    MobileRecordVPNEvent(path, event);
}

NSString *HyRouteVPNJournal(NSString *appPath, NSString *tunnelPath) {
    return MobileVPNJournal(appPath, tunnelPath) ?: @"[]";
}

NSObject * _Nullable HyRouteStartProbe(NSString *state, NSString *scope, NSString *profileID, NSString *journal) {
    NSError *error = nil;
    return MobileStartProbe(state, scope, profileID, journal, &error);
}

NSString * _Nullable HyRouteProbeSnapshot(NSObject *probe) {
    return [(MobileProbeBatch *)probe snapshot];
}

void HyRouteCancelProbe(NSObject *probe) {
    [(MobileProbeBatch *)probe cancel];
}
