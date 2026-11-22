#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
NSString * _Nullable HyRouteStateView(NSString *state);
NSString * _Nullable HyRouteAddSubscription(NSString *state, NSString *input, BOOL fromURL);
NSString * _Nullable HyRouteSaveSettings(NSString *state, NSString *settings);
void HyRouteConfigureGeo(NSString *directory);
NSString * _Nullable HyRouteGeoTags(void);
BOOL HyRouteUpdateGeo(void);
NS_ASSUME_NONNULL_END
