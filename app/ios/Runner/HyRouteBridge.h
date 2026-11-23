#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
NSString * _Nullable HyRouteStateView(NSString *state);
NSString * _Nullable HyRouteRecoveryState(NSString *state);
NSString * _Nullable HyRouteAddSubscription(NSString *state, NSString *input, BOOL fromURL);
NSString * _Nullable HyRouteRefreshSubscription(NSString *state, NSString *subscriptionID);
NSString * _Nullable HyRouteChangeRoutingProfile(NSString *state, NSString *operation, NSString *profileID, NSString *name, NSString * _Nullable * _Nonnull issue);
NSString * _Nullable HyRouteChangeServerGroup(NSString *state, NSString *groupID, NSString *definition, NSString * _Nullable * _Nonnull issue);
NSString * _Nullable HyRouteCheckClientRoute(NSString *state, NSString *address, NSString *ip, NSString *transport, NSString * _Nullable * _Nonnull issue);
NSString * _Nullable HyRouteAutoRefreshSubscriptions(NSString *state);
NSObject *HyRouteNewMaintenance(void);
void HyRouteCancelMaintenance(NSObject *maintenance);
NSString * _Nullable HyRouteRefreshWithMaintenance(NSObject *maintenance, NSString *state);
BOOL HyRouteUpdateGeoWithMaintenance(NSObject *maintenance, NSString *state);
NSString * _Nullable HyRouteSaveSettings(NSString *state, NSString *settings);
void HyRouteConfigureGeo(NSString *directory);
NSString * _Nullable HyRouteGeoTags(void);
BOOL HyRouteUpdateGeo(void);
BOOL HyRouteUpdateGeoForState(NSString *state);
BOOL HyRouteAutoUpdateGeoForState(NSString *state);
BOOL HyRouteAutoUpdateGeo(void);
NSString * _Nullable HyRouteGeoSettings(void);
BOOL HyRouteSetGeoSource(NSString *kind, NSString *address);
BOOL HyRouteImportGeoFile(NSString *kind, NSString *path);
BOOL HyRouteImportGeoFileForState(NSString *kind, NSString *path, NSString *state);
NSString *HyRouteUnavailableGeo(NSString *state);
NSString *HyRouteVPNGeodataKinds(NSString *state);
NSData * _Nullable HyRouteVPNGeodataSnapshot(NSString *state, NSString *directory);
BOOL HyRouteInstallVPNGeodataSnapshot(NSData *data, NSString *directory);
BOOL HyRouteInstallVPNGeodataSnapshotFile(NSString *path, NSString *directory);
NSObject * _Nullable HyRoutePlanVPN(NSString *state, NSString *geoDirectory, NSString * _Nullable * _Nonnull issue);
NSObject * _Nullable HyRoutePrepareVPN(NSObject *plan);
NSObject * _Nullable HyRouteStartVPN(NSObject *prepared, int32_t fd);
void HyRouteStopVPN(NSObject *session);
void HyRouteRecordVPNEvent(NSString *path, NSString *event);
void HyRouteRecordVPNError(NSString *path, NSString *event, NSString *source, int32_t code);
NSString *HyRouteVPNJournalEvents(NSString *appPath, NSString *tunnelPath);
NSObject * _Nullable HyRouteStartProbe(NSString *state, NSString *scope, NSString *profileID, NSString *journal);
NSString * _Nullable HyRouteProbeSnapshot(NSObject *probe);
void HyRouteCancelProbe(NSObject *probe);
NS_ASSUME_NONNULL_END
