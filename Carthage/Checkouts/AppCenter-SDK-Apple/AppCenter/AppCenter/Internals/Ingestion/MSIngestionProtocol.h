#import <Foundation/Foundation.h>

#import "MSEnable.h"
#import "MSIngestionCallDelegate.h"
#import "MSIngestionUtil.h"
#import "MS_Reachability.h"

NS_ASSUME_NONNULL_BEGIN

@protocol MSIngestionDelegate;

@protocol MSIngestionProtocol <NSObject, MSIngestionCallDelegate, MSEnable>

/**
 * Reachability library.
 */
@property(nonatomic) MS_Reachability *reachability;

/**
 * A boolean value set to YES if the ingestion is suspended or NO otherwise.
 */
@property(nonatomic) BOOL suspended;

/**
 * Send data.
 *
 * @param data Instance that will be transformed to request body.
 * @param appSecret The app secret.
 * @param handler Completion handler.
 */
- (void)sendAsync:(nullable NSObject *)data
            appSecret:(nullable NSString *)appSecret
    completionHandler:(MSSendAsyncCompletionHandler)handler;

/**
 *  Add the given delegate to the ingestion.
 *
 *  @param delegate Ingestion's delegate.
 */
- (void)addDelegate:(id<MSIngestionDelegate>)delegate;

/**
 *  Delete the given delegate from the ingestion.
 *
 *  @param delegate Ingestion's delegate.
 */
- (void)removeDelegate:(id<MSIngestionDelegate>)delegate;

/**
 * Suspend the ingestion.
 * An ingestion is suspended when it becomes disabled or on network issues.
 * A suspended state doesn't impact the current enabled state.
 * @see resume.
 */
- (void)suspend;

/**
 * Resume the ingestion.
 * @see suspend.
 */
- (void)resume;

@end

NS_ASSUME_NONNULL_END
