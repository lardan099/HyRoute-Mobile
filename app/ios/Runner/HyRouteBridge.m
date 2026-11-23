#import "HyRouteBridge.h"
#import <HyRouteCore/HyRouteCore.h>

NSString * _Nullable HyRouteRecoveryState(NSString *state) {
    NSError *error = nil;
    NSString *snapshot = MobileVPNRecoveryState(state, &error);
    return error == nil ? snapshot : nil;
}

NSString * _Nullable HyRouteStateView(NSString *state) {
    NSError *error = nil;
    NSString *view = MobileClientStateView(state, &error);
    return error == nil ? view : nil;
}

NSString * _Nullable HyRouteAddSubscription(NSString *state, NSString *input, BOOL fromURL) {
    NSString *issue = nil;
    return HyRouteAddSubscriptionWithIssue(state, input, fromURL, &issue);
}

NSString * _Nullable HyRouteAddSubscriptionWithIssue(NSString *state, NSString *input, BOOL fromURL, NSString * _Nullable * _Nonnull issue) {
    NSError *error = nil;
    NSString *updated = MobileAddClientSubscription(state, input, fromURL, &error);
    *issue = error == nil ? nil : MobileSubscriptionImportMessage(error.localizedDescription);
    return error == nil ? updated : nil;
}

void HyRouteConfigureSubscriptionDevice(NSString *version, NSString *seed, NSString *os, NSString *osVersion) {
    MobileConfigureSubscriptionDevice(version, seed, os, osVersion);
}

NSString * _Nullable HyRouteSaveSettings(NSString *state, NSString *settings) {
    NSString *issue = nil;
    return HyRouteSaveSettingsWithIssue(state, settings, &issue);
}

NSString * _Nullable HyRouteSaveSettingsWithIssue(NSString *state, NSString *settings, NSString * _Nullable * _Nonnull issue) {
    NSError *error = nil;
    NSString *updated = MobileSaveClientSettings(state, settings, NO, &error);
    *issue = error.localizedDescription;
    return error == nil ? updated : nil;
}

NSString * _Nullable HyRouteRefreshSubscription(NSString *state, NSString *subscriptionID) {
    NSError *error = nil;
    NSString *updated = MobileAttemptClientSubscriptionRefresh(state, subscriptionID, &error);
    return error == nil ? updated : nil;
}

NSString * _Nullable HyRouteChangeRoutingProfile(NSString *state, NSString *operation, NSString *profileID, NSString *name, NSString * _Nullable * _Nonnull issue) {
    NSError *error = nil;
    NSString *updated = MobileChangeRoutingProfile(state, operation, profileID, name, &error);
    *issue = error.localizedDescription;
    return error == nil ? updated : nil;
}

NSString * _Nullable HyRouteChangeServerGroup(NSString *state, NSString *groupID, NSString *definition, NSString * _Nullable * _Nonnull issue) {
    NSError *error = nil;
    NSString *updated = MobileChangeServerGroup(state, groupID, definition, &error);
    *issue = error.localizedDescription;
    return error == nil ? updated : nil;
}

NSString * _Nullable HyRouteCheckClientRoute(NSString *state, NSString *address, NSString *ip, NSString *transport, NSString * _Nullable * _Nonnull issue) {
    NSError *error = nil;
    NSString *route = MobileCheckClientRoute(state, address, ip, transport, @"", NO, &error);
    *issue = error.localizedDescription;
    return error == nil ? route : nil;
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

BOOL HyRouteUpdateGeoWithMaintenance(NSObject *maintenance, NSString *state) {
    NSError *error = nil;
    return [(MobileMaintenance *)maintenance updateGeoForState:state error:&error];
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

BOOL HyRouteUpdateGeoForState(NSString *state) {
    NSError *error = nil;
    return MobileUpdateGeoForState(state, &error);
}

BOOL HyRouteAutoUpdateGeoForState(NSString *state) {
    NSError *error = nil;
    return MobileAutoUpdateGeoForState(state, &error);
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

BOOL HyRouteImportGeoFileForState(NSString *kind, NSString *path, NSString *state) {
    NSError *error = nil;
    return MobileImportGeoFileForState(kind, path, state, &error);
}

NSString *HyRouteUnavailableGeo(NSString *state) {
    return [MobileInspectIOSVPNPlan(state) geoCategories];
}

NSString *HyRouteVPNGeodataKinds(NSString *state) {
    return MobileVPNGeodataKinds(state);
}

NSData * _Nullable HyRouteVPNGeodataSnapshot(NSString *state, NSString *directory) {
    NSError *error = nil;
    NSData *data = MobileVPNGeodataSnapshot(state, directory, &error);
    return error == nil ? data : nil;
}

BOOL HyRouteInstallVPNGeodataSnapshot(NSData *data, NSString *directory) {
    NSError *error = nil;
    return MobileInstallVPNGeodataSnapshot(data, directory, &error);
}

BOOL HyRouteInstallVPNGeodataSnapshotFile(NSString *path, NSString *directory) {
    NSError *error = nil;
    return MobileInstallVPNGeodataSnapshotFile(path, directory, &error);
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

BOOL HyRouteVPNHasChains(NSObject *prepared) {
    return [(MobileVPNPrepared *)prepared hasChains];
}

NSString *HyRouteCheckVPNChains(NSObject *session) {
    return [(MobileVPNSession *)session checkChains] ?: @"idle";
}

void HyRouteStopVPN(NSObject *session) {
    [(MobileVPNSession *)session stop];
}

void HyRouteSetTrafficLogging(NSObject *session, BOOL enabled) {
    [(MobileVPNSession *)session setTrafficLogging:enabled];
}

NSString *HyRouteTrafficEvents(NSObject *session) {
    return [(MobileVPNSession *)session trafficEvents] ?: @"[]";
}

void HyRouteClearTrafficEvents(NSObject *session) {
    [(MobileVPNSession *)session clearTrafficEvents];
}

void HyRouteRecordVPNEvent(NSString *path, NSString *event) {
    MobileRecordVPNEvent(path, event);
}

void HyRouteRecordVPNError(NSString *path, NSString *event, NSString *source, int32_t code) {
    MobileRecordVPNError(path, event, source, code);
}

NSString *HyRouteVPNJournalEvents(NSString *appPath, NSString *tunnelPath) {
    return MobileVPNJournalEvents(appPath, tunnelPath) ?: @"[]";
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
