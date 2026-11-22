#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
NSString * _Nullable HyRouteStateView(NSString *state);
NSString * _Nullable HyRouteAddSubscription(NSString *state, NSString *input, BOOL fromURL);
NSString * _Nullable HyRouteRefreshSubscription(NSString *state, NSString *subscriptionID);
NSString * _Nullable HyRouteAutoRefreshSubscriptions(NSString *state);
NSObject *HyRouteNewMaintenance(void);
void HyRouteCancelMaintenance(NSObject *maintenance);
NSString * _Nullable HyRouteRefreshWithMaintenance(NSObject *maintenance, NSString *state);
BOOL HyRouteUpdateGeoWithMaintenance(NSObject *maintenance);
NSString * _Nullable HyRouteSaveSettings(NSString *state, NSString *settings);
void HyRouteConfigureGeo(NSString *directory);
NSString * _Nullable HyRouteGeoTags(void);
BOOL HyRouteUpdateGeo(void);
BOOL HyRouteAutoUpdateGeo(void);
NSString * _Nullable HyRouteGeoSettings(void);
BOOL HyRouteSetGeoSource(NSString *kind, NSString *address);
BOOL HyRouteImportGeoFile(NSString *kind, NSString *path);
NSString *HyRouteUnavailableGeo(NSString *state);
NSObject * _Nullable HyRoutePlanVPN(NSString *state, NSString *geoDirectory, NSString * _Nullable * _Nonnull issue);
NSObject * _Nullable HyRoutePrepareVPN(NSObject *plan);
NSObject * _Nullable HyRouteStartVPN(NSObject *prepared, int32_t fd);
void HyRouteStopVPN(NSObject *session);
void HyRouteRecordVPNEvent(NSString *path, NSString *event);
void HyRouteRecordVPNError(NSString *path, NSString *event, NSString *source, int32_t code);
NSString *HyRouteVPNJournal(NSString *appPath, NSString *tunnelPath);
NSObject * _Nullable HyRouteStartProbe(NSString *state, NSString *scope, NSString *profileID, NSString *journal);
NSString * _Nullable HyRouteProbeSnapshot(NSObject *probe);
void HyRouteCancelProbe(NSObject *probe);
NS_ASSUME_NONNULL_END
