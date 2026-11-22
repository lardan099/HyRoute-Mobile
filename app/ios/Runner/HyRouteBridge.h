#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
NSString * _Nullable HyRouteStateView(NSString *state);
NSString * _Nullable HyRouteAddSubscription(NSString *state, NSString *input, BOOL fromURL);
NSString * _Nullable HyRouteRefreshSubscription(NSString *state, NSString *subscriptionID);
NSString * _Nullable HyRouteSaveSettings(NSString *state, NSString *settings);
void HyRouteConfigureGeo(NSString *directory);
NSString * _Nullable HyRouteGeoTags(void);
BOOL HyRouteUpdateGeo(void);
NSObject * _Nullable HyRoutePrepareVPN(NSString *state, NSString *geoDirectory);
NSObject * _Nullable HyRouteStartVPN(NSObject *prepared, int32_t fd);
void HyRouteStopVPN(NSObject *session);
NS_ASSUME_NONNULL_END
