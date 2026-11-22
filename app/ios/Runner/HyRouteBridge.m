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

NSString * _Nullable HyRouteAutoRefreshSubscriptions(NSString *state) {
    NSError *error = nil;
    NSString *updated = MobileAutoRefreshSubscriptions(state, &error);
    return error == nil ? updated : nil;
}

NSObject *HyRouteNewMaintenance(void) {
    return MobileNewMaintenance();
}

void HyRouteCancelMaintenance(NSObject *maintenance) {
    [(MobileMaintenance *)maintenance cancel];
}

NSString * _Nullable HyRouteRefreshWithMaintenance(NSObject *maintenance, NSString *state) {
    NSError *error = nil;
    NSString *updated = [(MobileMaintenance *)maintenance refreshSubscriptions:state error:&error];
    return error == nil ? updated : nil;
}

BOOL HyRouteUpdateGeoWithMaintenance(NSObject *maintenance) {
    NSError *error = nil;
    return [(MobileMaintenance *)maintenance updateGeo:&error];
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

BOOL HyRouteAutoUpdateGeo(void) {
    NSError *error = nil;
    return MobileAutoUpdateGeo(&error);
}

NSString * _Nullable HyRouteGeoSettings(void) {
    NSError *error = nil;
    NSString *settings = MobileGeoSettings(&error);
    return error == nil ? settings : nil;
}

BOOL HyRouteSetGeoSource(NSString *kind, NSString *address) {
    NSError *error = nil;
    return MobileSetGeoSource(kind, address, &error);
}

BOOL HyRouteImportGeoFile(NSString *kind, NSString *path) {
    NSError *error = nil;
    return MobileImportGeoFile(kind, path, &error);
}

NSString *HyRouteUnavailableGeo(NSString *state) {
    return [MobileInspectIOSVPNPlan(state) geoCategories];
}

NSObject * _Nullable HyRoutePlanVPN(NSString *state, NSString *geoDirectory, NSString * _Nullable * _Nonnull issue) {
    MobileConfigureGeo(geoDirectory);
    MobileIOSVPNPlanResult *result = MobileInspectIOSVPNPlan(state);
    *issue = [result issue];
    return [result plan];
}

NSObject * _Nullable HyRoutePrepareVPN(NSObject *plan) {
    NSError *error = nil;
    return [(MobileVPNPlan *)plan prepare:&error];
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

void HyRouteRecordVPNError(NSString *path, NSString *event, NSString *source, int32_t code) {
    MobileRecordVPNError(path, event, source, code);
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
