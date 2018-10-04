#import <Foundation/Foundation.h>

@class MSDevice;

/**
 * Provide and keep track of device log based on collected properties.
 */
@interface MSDeviceTracker : NSObject

/**
 * Current device log. This will be updated on app launch.
 */
@property(nonatomic, readonly) MSDevice *device;

/**
 * Returns singleton instance of MSDeviceTracker.
 *
 * @return an instance of MSDeviceTracker.
 */
+ (instancetype)sharedInstance;

@end
