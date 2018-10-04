#import "MSHttpTestUtil.h"
#import "MSConstants+Internal.h"
#import <OHHTTPStubs/OHHTTPStubs.h>

/*
 * TODO: We need to reduce this response time from UID_MAX to 2.0 because
 * [OHHTTPStubs removeAllStubs] is called before timeout and it results a crash
 * with succeeded test. Testing on Xcode 8 doesn't have any issues on it but
 * Xcode 9 complains. Keep in mind that 2 sec timeout is not somewhat we get
 * from accurate testing, it is a heuristic number and it might fail any unit
 * tests.
 */
static NSTimeInterval const kMSStubbedResponseTimeout = 2.0;
static NSString *const kMSStub500Name = @"httpStub_500";
static NSString *const kMSStub404Name = @"httpStub_404";
static NSString *const kMSStub200Name = @"httpStub_200";
static NSString *const kMSStubNetworkDownName = @"httpStub_NetworkDown";
static NSString *const kMSStubLongResponseTimeOutName =
    @"httpStub_LongResponseTimeOut";

@implementation MSHttpTestUtil

+ (void)stubHttp500Response {
  [[self class] stubResponseWithCode:MSHTTPCodesNo500InternalServerError
                                name:kMSStub500Name];
}

+ (void)stubHttp404Response {
  [[self class] stubResponseWithCode:MSHTTPCodesNo404NotFound
                                name:kMSStub404Name];
}

+ (void)stubHttp200Response {
  [[self class] stubResponseWithCode:MSHTTPCodesNo200OK name:kMSStub200Name];
}

+ (void)removeAllStubs {
  [OHHTTPStubs removeAllStubs];
}

+ (void)stubNetworkDownResponse {
  NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                       code:kCFURLErrorNotConnectedToInternet
                                   userInfo:nil];
  [[self class] stubResponseWithError:error name:kMSStubNetworkDownName];
}

+ (void)stubLongTimeOutResponse {
  [OHHTTPStubs stubRequestsPassingTest:^BOOL(__attribute__((unused))
                                             NSURLRequest *request) {
    return YES;
  }
      withStubResponse:^OHHTTPStubsResponse *(__attribute__((unused))
                                              NSURLRequest *request) {
        OHHTTPStubsResponse *responseStub = [OHHTTPStubsResponse new];
        responseStub.statusCode = MSHTTPCodesNo200OK;
        return [responseStub responseTime:kMSStubbedResponseTimeout];
      }]
      .name = kMSStubLongResponseTimeOutName;
}

+ (void)stubResponseWithCode:(NSInteger)code name:(NSString *)name {
  [OHHTTPStubs stubRequestsPassingTest:^BOOL(__attribute__((unused))
                                             NSURLRequest *request) {
    return YES;
  }
      withStubResponse:^OHHTTPStubsResponse *(__attribute__((unused))
                                              NSURLRequest *request) {
        OHHTTPStubsResponse *responseStub = [OHHTTPStubsResponse new];
        responseStub.statusCode = (int)code;
        return responseStub;
      }]
      .name = name;
}

+ (void)stubResponseWithError:(NSError *)error name:(NSString *)name {
  [OHHTTPStubs stubRequestsPassingTest:^BOOL(__attribute__((unused))
                                             NSURLRequest *request) {
    return YES;
  }
      withStubResponse:^OHHTTPStubsResponse *(__attribute__((unused))
                                              NSURLRequest *request) {
        return [OHHTTPStubsResponse responseWithError:error];
      }]
      .name = name;
}

@end
