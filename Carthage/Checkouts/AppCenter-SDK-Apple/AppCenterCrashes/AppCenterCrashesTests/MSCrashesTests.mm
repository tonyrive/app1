#import "MSAppCenterInternal.h"
#import "MSAppleErrorLog.h"
#import "MSChannelGroupDefault.h"
#import "MSChannelUnitConfiguration.h"
#import "MSChannelUnitDefault.h"
#import "MSConstants+Internal.h"
#import "MSCrashesDelegate.h"
#import "MSCrashesInternal.h"
#import "MSCrashesPrivate.h"
#import "MSCrashesTestUtil.h"
#import "MSCrashesUtil.h"
#import "MSCrashHandlerSetupDelegate.h"
#import "MSErrorAttachmentLogInternal.h"
#import "MSErrorLogFormatter.h"
#import "MSException.h"
#import "MSHandledErrorLog.h"
#import "MSLoggerInternal.h"
#import "MSMockCrashesDelegate.h"
#import "MSMockUserDefaults.h"
#import "MSServiceAbstractProtected.h"
#import "MSTestFrameworks.h"
#import "MSUtility+File.h"
#import "MSWrapperCrashesHelper.h"
#import "MSWrapperExceptionManagerInternal.h"

@class MSMockCrashesDelegate;

static NSString *const kMSTestAppSecret = @"TestAppSecret";
static NSString *const kMSCrashesServiceName = @"Crashes";
static NSString *const kMSFatal = @"fatal";
static NSString *const kMSTypeHandledError = @"handledError";
static NSString *const kMSUserConfirmationKey = @"MSUserConfirmation";
static unsigned int kMaxAttachmentsPerCrashReport = 2;

@interface MSCrashes ()

+ (void)notifyWithUserConfirmation:(MSUserConfirmation)userConfirmation;
- (void)startDelayedCrashProcessing;
- (void)startCrashProcessing;
- (void)shouldAlwaysSend;
- (void)emptyLogBufferFiles;

@property(nonatomic) dispatch_group_t bufferFileGroup;

@end

@interface MSCrashesTests : XCTestCase <MSCrashesDelegate>

@property(nonatomic) MSCrashes *sut;

@end

@implementation MSCrashesTests

#pragma mark - Housekeeping

- (void)setUp {
  [super setUp];
  self.sut = [MSCrashes new];
}

- (void)tearDown {
  [super tearDown];

  // Make sure sessionTracker removes all observers.
  [MSCrashes resetSharedInstance];

  // Wait for creation of buffers.
  dispatch_group_wait(self.sut.bufferFileGroup, DISPATCH_TIME_FOREVER);

  // Delete all files.
  [self.sut deleteAllFromCrashesDirectory];
  NSString *logBufferDir = [MSCrashesUtil logBufferDir];
  [MSUtility deleteItemForPathComponent:logBufferDir];
}

#pragma mark - Tests

- (void)testNewInstanceWasInitialisedCorrectly {

  // When
  // An instance of MSCrashes is created.

  // Then
  assertThat(self.sut, notNilValue());
  assertThat(self.sut.crashFiles, isEmpty());
  assertThat(self.sut.analyzerInProgressFilePathComponent, notNilValue());
  XCTAssertTrue(msCrashesLogBuffer.size() == ms_crashes_log_buffer_size);

  // Wait for creation of buffers.
  dispatch_group_wait(self.sut.bufferFileGroup, DISPATCH_TIME_FOREVER);
  NSArray *files = [MSUtility contentsOfDirectory:self.sut.logBufferPathComponent propertiesForKeys:nil];
  assertThat(files, hasCountOf(ms_crashes_log_buffer_size));
}

- (void)testStartingManagerInitializesPLCrashReporter {

  // When
  [self.sut startWithChannelGroup:OCMProtocolMock(@protocol(MSChannelGroupProtocol))
                        appSecret:kMSTestAppSecret
          transmissionTargetToken:nil
                  fromApplication:YES];

  // Then
  assertThat(self.sut.plCrashReporter, notNilValue());
}

- (void)testStartingManagerWritesLastCrashReportToCrashesDir {
  assertThatBool([MSCrashesTestUtil copyFixtureCrashReportWithFileName:@"live_report_exception"], isTrue());

  // When
  [self.sut startWithChannelGroup:OCMProtocolMock(@protocol(MSChannelGroupProtocol))
                        appSecret:kMSTestAppSecret
          transmissionTargetToken:nil
                  fromApplication:YES];

  // Then
  assertThat(self.sut.crashFiles, hasCountOf(1));
}

- (void)testSettingDelegateWorks {

  // When
  id<MSCrashesDelegate> delegateMock = OCMProtocolMock(@protocol(MSCrashesDelegate));
  [MSCrashes setDelegate:delegateMock];

  // Then
  id<MSCrashesDelegate> strongDelegate = [MSCrashes sharedInstance].delegate;
  XCTAssertNotNil(strongDelegate);
  XCTAssertEqual(strongDelegate, delegateMock);
}

- (void)testDelegateMethodsAreCalled {

  // If
  id<MSCrashesDelegate> delegateMock = OCMProtocolMock(@protocol(MSCrashesDelegate));
  [MSAppCenter sharedInstance].sdkConfigured = NO;
  [MSAppCenter start:kMSTestAppSecret withServices:@[ [MSCrashes class] ]];
  MSAppleErrorLog *errorLog = OCMClassMock([MSAppleErrorLog class]);
  MSErrorReport *errorReport = OCMClassMock([MSErrorReport class]);
  id errorLogFormatterMock = OCMClassMock([MSErrorLogFormatter class]);
  OCMStub(ClassMethod([errorLogFormatterMock errorReportFromLog:errorLog])).andReturn(errorReport);

  // When
  [[MSCrashes sharedInstance] setDelegate:delegateMock];
  id<MSChannelProtocol> channel = [MSCrashes sharedInstance].channelUnit;
  id<MSLog> log = errorLog;
  [[MSCrashes sharedInstance] channel:channel willSendLog:log];
  [[MSCrashes sharedInstance] channel:channel didSucceedSendingLog:log];
  [[MSCrashes sharedInstance] channel:channel didFailSendingLog:log withError:nil];

  // Then
  OCMVerify([delegateMock crashes:[MSCrashes sharedInstance] willSendErrorReport:errorReport]);
  OCMVerify([delegateMock crashes:[MSCrashes sharedInstance] didSucceedSendingErrorReport:errorReport]);
  OCMVerify([delegateMock crashes:[MSCrashes sharedInstance] didFailSendingErrorReport:errorReport withError:nil]);
}

- (void)testCrashHandlerSetupDelegateMethodsAreCalled {

  // If
  id<MSCrashHandlerSetupDelegate> delegateMock = OCMProtocolMock(@protocol(MSCrashHandlerSetupDelegate));
  [MSWrapperCrashesHelper setCrashHandlerSetupDelegate:delegateMock];

  // When
  [self.sut applyEnabledState:YES];

  // Then
  OCMVerify([delegateMock willSetUpCrashHandlers]);
  OCMVerify([delegateMock didSetUpCrashHandlers]);
  OCMVerify([delegateMock shouldEnableUncaughtExceptionHandler]);
}

- (void)testSettingUserConfirmationHandler {

  // When
  MSUserConfirmationHandler userConfirmationHandler =
      ^BOOL(__attribute__((unused)) NSArray<MSErrorReport *> *_Nonnull errorReports) {
        return NO;
      };
  [MSCrashes setUserConfirmationHandler:userConfirmationHandler];

  // Then
  XCTAssertNotNil([MSCrashes sharedInstance].userConfirmationHandler);
  XCTAssertEqual([MSCrashes sharedInstance].userConfirmationHandler, userConfirmationHandler);
}

- (void)testCrashesDelegateWithoutImplementations {

  // When
  MSMockCrashesDelegate *delegateMock = OCMPartialMock([MSMockCrashesDelegate new]);
  [MSCrashes setDelegate:delegateMock];

  // Then
  assertThatBool([[MSCrashes sharedInstance] shouldProcessErrorReport:nil], isTrue());
  assertThatBool([[MSCrashes sharedInstance] delegateImplementsAttachmentCallback], isFalse());
}

- (void)testProcessCrashes {

  // Wait for creation of buffers to avoid corruption on OCMPartialMock.
  dispatch_group_wait(self.sut.bufferFileGroup, DISPATCH_TIME_FOREVER);

  // If
  self.sut = OCMPartialMock(self.sut);
  OCMStub([self.sut startDelayedCrashProcessing]).andDo(nil);

  // When
  assertThatBool([MSCrashesTestUtil copyFixtureCrashReportWithFileName:@"live_report_exception"], isTrue());
  [self.sut startWithChannelGroup:OCMProtocolMock(@protocol(MSChannelGroupProtocol))
                        appSecret:kMSTestAppSecret
          transmissionTargetToken:nil
                  fromApplication:YES];

  // Then
  assertThat(self.sut.crashFiles, hasCountOf(1));

  // When
  OCMStub([self.sut shouldAlwaysSend]).andReturn(YES);
  [self.sut startCrashProcessing];
  OCMStub([self.sut shouldAlwaysSend]).andReturn(NO);

  // Then
  assertThat(self.sut.crashFiles, hasCountOf(0));

  // When
  self.sut = OCMPartialMock([MSCrashes new]);
  OCMStub([self.sut startDelayedCrashProcessing]).andDo(nil);
  assertThatBool([MSCrashesTestUtil copyFixtureCrashReportWithFileName:@"live_report_exception"], isTrue());
  [self.sut startWithChannelGroup:OCMProtocolMock(@protocol(MSChannelGroupProtocol))
                        appSecret:kMSTestAppSecret
          transmissionTargetToken:nil
                  fromApplication:YES];

  // Then
  assertThat(self.sut.crashFiles, hasCountOf(1));
  assertThatLong([MSUtility contentsOfDirectory:self.sut.crashesPathComponent propertiesForKeys:nil].count,
                 equalToLong(1));

  // When
  self.sut = OCMPartialMock([MSCrashes new]);
  OCMStub([self.sut startDelayedCrashProcessing]).andDo(nil);
  MSUserConfirmationHandler userConfirmationHandlerYES =
      ^BOOL(__attribute__((unused)) NSArray<MSErrorReport *> *_Nonnull errorReports) {
        return YES;
      };

  self.sut.userConfirmationHandler = userConfirmationHandlerYES;
  [self.sut startWithChannelGroup:OCMProtocolMock(@protocol(MSChannelGroupProtocol))
                        appSecret:kMSTestAppSecret
          transmissionTargetToken:nil
                  fromApplication:YES];
  [self.sut startCrashProcessing];
  [self.sut notifyWithUserConfirmation:MSUserConfirmationDontSend];
  self.sut.userConfirmationHandler = nil;

  // Then
  assertThat(self.sut.crashFiles, hasCountOf(0));
  assertThatLong([MSUtility contentsOfDirectory:self.sut.crashesPathComponent propertiesForKeys:nil].count,
                 equalToLong(0));

  // When
  self.sut = OCMPartialMock([MSCrashes new]);
  OCMStub([self.sut startDelayedCrashProcessing]).andDo(nil);
  assertThatBool([MSCrashesTestUtil copyFixtureCrashReportWithFileName:@"live_report_exception"], isTrue());
  [self.sut startWithChannelGroup:OCMProtocolMock(@protocol(MSChannelGroupProtocol))
                        appSecret:kMSTestAppSecret
          transmissionTargetToken:nil
                  fromApplication:YES];

  // Then
  assertThat(self.sut.crashFiles, hasCountOf(1));
  assertThatLong([MSUtility contentsOfDirectory:self.sut.crashesPathComponent propertiesForKeys:nil].count,
                 equalToLong(1));

  // When
  self.sut = OCMPartialMock([MSCrashes new]);
  OCMStub([self.sut startDelayedCrashProcessing]).andDo(nil);
  MSUserConfirmationHandler userConfirmationHandlerNO =
      ^BOOL(__attribute__((unused)) NSArray<MSErrorReport *> *_Nonnull errorReports) {
        return NO;
      };
  self.sut.userConfirmationHandler = userConfirmationHandlerNO;
  [self.sut startWithChannelGroup:OCMProtocolMock(@protocol(MSChannelGroupProtocol))
                        appSecret:kMSTestAppSecret
          transmissionTargetToken:nil
                  fromApplication:YES];
  [self.sut startCrashProcessing];

  // Then
  assertThat(self.sut.crashFiles, hasCountOf(0));
  assertThatLong([MSUtility contentsOfDirectory:self.sut.crashesPathComponent propertiesForKeys:nil].count,
                 equalToLong(0));
}

- (void)testProcessCrashesWithErrorAttachments {

  // Wait for creation of buffers to avoid corruption on OCMPartialMock.
  dispatch_group_wait(self.sut.bufferFileGroup, DISPATCH_TIME_FOREVER);

  // If
  self.sut = OCMPartialMock(self.sut);
  OCMStub([self.sut startDelayedCrashProcessing]).andDo(nil);

  // When
  id channelGroupMock = OCMProtocolMock(@protocol(MSChannelGroupProtocol));
  assertThatBool([MSCrashesTestUtil copyFixtureCrashReportWithFileName:@"live_report_exception"], isTrue());
  NSString *validString = @"valid";
  NSData *validData = [validString dataUsingEncoding:NSUTF8StringEncoding];
  NSData *emptyData = [@"" dataUsingEncoding:NSUTF8StringEncoding];
  NSArray *invalidLogs = @[
    [self attachmentWithAttachmentId:nil attachmentData:validData contentType:validString],
    [self attachmentWithAttachmentId:@"" attachmentData:validData contentType:validString],
    [self attachmentWithAttachmentId:validString attachmentData:nil contentType:validString],
    [self attachmentWithAttachmentId:validString attachmentData:emptyData contentType:validString],
    [self attachmentWithAttachmentId:validString attachmentData:validData contentType:nil],
    [self attachmentWithAttachmentId:validString attachmentData:validData contentType:@""]
  ];
  id channelUnitMock = OCMProtocolMock(@protocol(MSChannelUnitProtocol));
  OCMStub([channelGroupMock
              addChannelUnitWithConfiguration:[OCMArg checkWithBlock:^BOOL(MSChannelUnitConfiguration *configuration) {
                return [configuration.groupId isEqualToString:@"Crashes"];
              }]])
      .andReturn(channelUnitMock);
  for (NSUInteger i = 0; i < invalidLogs.count; i++) {
    OCMReject([channelUnitMock enqueueItem:invalidLogs[i]]);
  }
  MSErrorAttachmentLog *validLog =
      [self attachmentWithAttachmentId:validString attachmentData:validData contentType:validString];
  NSMutableArray *logs = invalidLogs.mutableCopy;
  [logs addObject:validLog];
  id crashesDelegateMock = OCMProtocolMock(@protocol(MSCrashesDelegate));
  OCMStub([crashesDelegateMock attachmentsWithCrashes:OCMOCK_ANY forErrorReport:OCMOCK_ANY]).andReturn(logs);
  OCMStub([crashesDelegateMock crashes:OCMOCK_ANY shouldProcessErrorReport:OCMOCK_ANY]).andReturn(YES);
  [self.sut startWithChannelGroup:channelGroupMock
                        appSecret:kMSTestAppSecret
          transmissionTargetToken:nil
                  fromApplication:YES];
  [self.sut setDelegate:crashesDelegateMock];

  // Then
  OCMExpect([channelUnitMock enqueueItem:validLog]);
  [self.sut startCrashProcessing];
  OCMVerifyAll(channelUnitMock);
}

- (void)testDeleteAllFromCrashesDirectory {

  // If
  assertThatBool([MSCrashesTestUtil copyFixtureCrashReportWithFileName:@"live_report_exception"], isTrue());
  [self.sut startWithChannelGroup:OCMProtocolMock(@protocol(MSChannelGroupProtocol))
                        appSecret:kMSTestAppSecret
          transmissionTargetToken:nil
                  fromApplication:YES];
  assertThatBool([MSCrashesTestUtil copyFixtureCrashReportWithFileName:@"live_report_signal"], isTrue());
  [self.sut startWithChannelGroup:OCMProtocolMock(@protocol(MSChannelGroupProtocol))
                        appSecret:kMSTestAppSecret
          transmissionTargetToken:nil
                  fromApplication:YES];

  // When
  [self.sut deleteAllFromCrashesDirectory];

  // Then
  assertThat(self.sut.crashFiles, hasCountOf(0));
}

- (void)testDeleteCrashReportsOnDisabled {

  // If
  MSMockUserDefaults *settings = [MSMockUserDefaults new];
  [settings setObject:@(YES) forKey:self.sut.isEnabledKey];
  assertThatBool([MSCrashesTestUtil copyFixtureCrashReportWithFileName:@"live_report_exception"], isTrue());
  [self.sut startWithChannelGroup:OCMProtocolMock(@protocol(MSChannelGroupProtocol))
                        appSecret:kMSTestAppSecret
          transmissionTargetToken:nil
                  fromApplication:YES];

  // When
  [self.sut setEnabled:NO];

  // Then
  assertThat(self.sut.crashFiles, hasCountOf(0));
  assertThatLong([MSUtility contentsOfDirectory:self.sut.crashesPathComponent propertiesForKeys:nil].count,
                 equalToLong(0));
  [settings stopMocking];
}

- (void)testDeleteCrashReportsFromDisabledToEnabled {

  // If
  MSMockUserDefaults *settings = [MSMockUserDefaults new];
  [settings setObject:@(NO) forKey:self.sut.isEnabledKey];
  assertThatBool([MSCrashesTestUtil copyFixtureCrashReportWithFileName:@"live_report_exception"], isTrue());
  [self.sut startWithChannelGroup:OCMProtocolMock(@protocol(MSChannelGroupProtocol))
                        appSecret:kMSTestAppSecret
          transmissionTargetToken:nil
                  fromApplication:YES];

  // When
  [self.sut setEnabled:YES];

  // Then
  assertThat(self.sut.crashFiles, hasCountOf(0));
  assertThatLong([MSUtility contentsOfDirectory:self.sut.crashesPathComponent propertiesForKeys:nil].count,
                 equalToLong(0));
  [settings stopMocking];
}

- (void)testSetupLogBufferWorks {

  // If
  // Wait for creation of buffers.
  dispatch_group_wait(self.sut.bufferFileGroup, DISPATCH_TIME_FOREVER);

  // Then
  NSArray<NSURL *> *first = [MSUtility contentsOfDirectory:self.sut.logBufferPathComponent
                                         propertiesForKeys:@[ NSURLNameKey, NSURLFileSizeKey, NSURLIsRegularFileKey ]];
  XCTAssertTrue(first.count == ms_crashes_log_buffer_size);
  for (NSURL *path in first) {
    unsigned long long fileSize =
        [[[NSFileManager defaultManager] attributesOfItemAtPath:([path absoluteString] ?: @"") error:nil] fileSize];
    XCTAssertTrue(fileSize == 0);
  }

  // When
  [self.sut setupLogBuffer];

  // Then
  NSArray *second = [MSUtility contentsOfDirectory:self.sut.logBufferPathComponent propertiesForKeys:nil];
  for (int i = 0; i < ms_crashes_log_buffer_size; i++) {
    XCTAssertTrue([([first[i] absoluteString] ?: @"") isEqualToString:([second[i] absoluteString] ?: @"")]);
  }
}

- (void)testEmptyLogBufferFiles {

  // If
  NSString *testName = @"afilename";
  NSString *dataString = @"SomeBufferedData";
  NSData *someData = [dataString dataUsingEncoding:NSUTF8StringEncoding];
  NSString *filePath = [NSString stringWithFormat:@"%@/%@", self.sut.logBufferPathComponent,
                                                  [testName stringByAppendingString:@".mscrasheslogbuffer"]];
  [MSUtility createFileAtPathComponent:filePath withData:someData atomically:YES forceOverwrite:YES];

  // When
  BOOL success = [MSUtility fileExistsForPathComponent:filePath];
  XCTAssertTrue(success);

  // Then
  NSData *data = [MSUtility loadDataForPathComponent:filePath];
  XCTAssertTrue([data length] == 16);

  // When
  [self.sut emptyLogBufferFiles];

  // Then
  data = [MSUtility loadDataForPathComponent:filePath];
  XCTAssertTrue([data length] == 0);
}

- (void)testBufferIndexIncrementForAllPriorities {

  // When
  MSLogWithProperties *log = [MSLogWithProperties new];
  [self.sut channel:nil didPrepareLog:log withInternalId:MS_UUID_STRING];

  // Then
  XCTAssertTrue([self crashesLogBufferCount] == 1);
}

- (void)testBufferIndexOverflowForAllPriorities {

  // When
  for (int i = 0; i < ms_crashes_log_buffer_size; i++) {
    MSLogWithProperties *log = [MSLogWithProperties new];
    [self.sut channel:nil didPrepareLog:log withInternalId:MS_UUID_STRING];
  }

  // Then
  XCTAssertTrue([self crashesLogBufferCount] == ms_crashes_log_buffer_size);

  // When
  MSLogWithProperties *log = [MSLogWithProperties new];
  [self.sut channel:nil didPrepareLog:log withInternalId:MS_UUID_STRING];
  NSNumberFormatter *timestampFormatter = [[NSNumberFormatter alloc] init];
  timestampFormatter.numberStyle = NSNumberFormatterDecimalStyle;
  int indexOfLatestObject = 0;
  NSNumber *oldestTimestamp;
  for (auto it = msCrashesLogBuffer.begin(), end = msCrashesLogBuffer.end(); it != end; ++it) {
    NSString *timestampString = [NSString stringWithCString:it->timestamp.c_str() encoding:NSUTF8StringEncoding];
    NSNumber *bufferedLogTimestamp = [timestampFormatter numberFromString:timestampString];

    // Remember the timestamp if the log is older than the previous one or the initial one.
    if (!oldestTimestamp || oldestTimestamp.doubleValue > bufferedLogTimestamp.doubleValue) {
      oldestTimestamp = bufferedLogTimestamp;
      indexOfLatestObject = static_cast<int>(it - msCrashesLogBuffer.begin());
    }
  }
  // Then
  XCTAssertTrue([self crashesLogBufferCount] == ms_crashes_log_buffer_size);
  XCTAssertTrue(indexOfLatestObject == 1);

  // If
  int numberOfLogs = 50;
  // When
  for (int i = 0; i < numberOfLogs; i++) {
    MSLogWithProperties *aLog = [MSLogWithProperties new];
    [self.sut channel:nil didPrepareLog:aLog withInternalId:MS_UUID_STRING];
  }

  indexOfLatestObject = 0;
  oldestTimestamp = nil;
  for (auto it = msCrashesLogBuffer.begin(), end = msCrashesLogBuffer.end(); it != end; ++it) {
    NSString *timestampString = [NSString stringWithCString:it->timestamp.c_str() encoding:NSUTF8StringEncoding];
    NSNumber *bufferedLogTimestamp = [timestampFormatter numberFromString:timestampString];

    // Remember the timestamp if the log is older than the previous one or the initial one.
    if (!oldestTimestamp || oldestTimestamp.doubleValue > bufferedLogTimestamp.doubleValue) {
      oldestTimestamp = bufferedLogTimestamp;
      indexOfLatestObject = static_cast<int>(it - msCrashesLogBuffer.begin());
    }
  }

  // Then
  XCTAssertTrue([self crashesLogBufferCount] == ms_crashes_log_buffer_size);
  XCTAssertTrue(indexOfLatestObject == (1 + (numberOfLogs % ms_crashes_log_buffer_size)));
}

- (void)testBufferIndexOnPersistingLog {

  // When
  MSCommonSchemaLog *commonSchemaLog = [MSCommonSchemaLog new];
  [commonSchemaLog addTransmissionTargetToken:MS_UUID_STRING];
  NSString *uuid1 = MS_UUID_STRING;
  NSString *uuid2 = MS_UUID_STRING;
  NSString *uuid3 = MS_UUID_STRING;
  [self.sut channel:nil didPrepareLog:[MSLogWithProperties new] withInternalId:uuid1];
  [self.sut channel:nil didPrepareLog:commonSchemaLog withInternalId:uuid2];
  
  // Don't buffer event if log is related to crash.
  [self.sut channel:nil didPrepareLog:[MSAppleErrorLog new] withInternalId:uuid3];

  // Then
  assertThatLong([self crashesLogBufferCount], equalToLong(2));
  
  // When
  [self.sut channel:nil didCompleteEnqueueingLog:nil withInternalId:uuid3];
  
  // Then
  assertThatLong([self crashesLogBufferCount], equalToLong(2));

  // When
  [self.sut channel:nil didCompleteEnqueueingLog:nil withInternalId:uuid2];

  // Then
  assertThatLong([self crashesLogBufferCount], equalToLong(1));

  // When
  [self.sut channel:nil didCompleteEnqueueingLog:nil withInternalId:uuid1];

  // Then
  assertThatLong([self crashesLogBufferCount], equalToLong(0));
}

- (void)testLogBufferSave {
  
  // If
  __block NSUInteger numInvocations = 0;
  id<MSChannelUnitProtocol> channelUnitMock = OCMProtocolMock(@protocol(MSChannelUnitProtocol));
  id<MSChannelGroupProtocol> channelGroupMock = OCMProtocolMock(@protocol(MSChannelGroupProtocol));
  OCMStub([channelGroupMock
           addChannelUnitWithConfiguration:[OCMArg checkWithBlock:^BOOL(MSChannelUnitConfiguration *configuration) {
    return [configuration.groupId isEqualToString:@"CrashesBuffer"];
  }]]).andReturn(channelUnitMock);
  OCMStub([channelUnitMock enqueueItem:OCMOCK_ANY])
    .andDo(^(__unused NSInvocation *invocation) {
      numInvocations++;
    });
  
  // When
  MSCommonSchemaLog *commonSchemaLog = [MSCommonSchemaLog new];
  [commonSchemaLog addTransmissionTargetToken:MS_UUID_STRING];
  NSString *uuid1 = MS_UUID_STRING;
  NSString *uuid2 = MS_UUID_STRING;
  NSString *uuid3 = MS_UUID_STRING;
  [self.sut channel:nil didPrepareLog:[MSLogWithProperties new] withInternalId:uuid1];
  [self.sut channel:nil didPrepareLog:commonSchemaLog withInternalId:uuid2];
  
  // Don't buffer event if log is related to crash.
  [self.sut channel:nil didPrepareLog:[MSAppleErrorLog new] withInternalId:uuid3];
  
  // Then
  assertThatLong([self crashesLogBufferCount], equalToLong(2));
  
  // When
  // Save on crash.
  ms_save_log_buffer();
  
  // Recreate crashes.
  [self.sut startWithChannelGroup:channelGroupMock
                        appSecret:kMSTestAppSecret
          transmissionTargetToken:nil
                  fromApplication:YES];

  // Then
  XCTAssertEqual(2U, numInvocations);
}

- (void)testInitializationPriorityCorrect {
  XCTAssertTrue([[MSCrashes sharedInstance] initializationPriority] == MSInitializationPriorityMax);
}

// The Mach exception handler is not supported on tvOS.
#if TARGET_OS_TV
- (void)testMachExceptionHandlerDisabledOnTvOS {

  // Then
  XCTAssertFalse([[MSCrashes sharedInstance] isMachExceptionHandlerEnabled]);
}
#else
- (void)testDisableMachExceptionWorks {

  // Then
  XCTAssertTrue([[MSCrashes sharedInstance] isMachExceptionHandlerEnabled]);

  // When
  [MSCrashes disableMachExceptionHandler];

  // Then
  XCTAssertFalse([[MSCrashes sharedInstance] isMachExceptionHandlerEnabled]);

  // Then
  XCTAssertTrue([self.sut isMachExceptionHandlerEnabled]);

  // When
  [self.sut setEnableMachExceptionHandler:NO];

  // Then
  XCTAssertFalse([self.sut isMachExceptionHandlerEnabled]);
}

#endif

- (void)testAbstractErrorLogSerialization {
  MSAbstractErrorLog *log = [MSAbstractErrorLog new];

  // When
  NSDictionary *serializedLog = [log serializeToDictionary];

  // Then
  XCTAssertFalse([static_cast<NSNumber *>([serializedLog objectForKey:kMSFatal]) boolValue]);

  // If
  log.fatal = NO;

  // When
  serializedLog = [log serializeToDictionary];

  // Then
  XCTAssertFalse([static_cast<NSNumber *>([serializedLog objectForKey:kMSFatal]) boolValue]);

  // If
  log.fatal = YES;

  // When
  serializedLog = [log serializeToDictionary];

  // Then
  XCTAssertTrue([static_cast<NSNumber *>([serializedLog objectForKey:kMSFatal]) boolValue]);
}

- (void)testWarningMessageAboutTooManyErrorAttachments {

  NSString *expectedMessage =
      [NSString stringWithFormat:@"A limit of %u attachments per error report might be enforced by server.",
                                 kMaxAttachmentsPerCrashReport];
  __block bool warningMessageHasBeenPrinted = false;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
  [MSLogger setLogHandler:^(MSLogMessageProvider messageProvider, MSLogLevel logLevel, NSString *tag, const char *file,
                            const char *function, uint line) {
    if (warningMessageHasBeenPrinted) {
      return;
    }
    NSString *message = messageProvider();
    warningMessageHasBeenPrinted = [message isEqualToString:expectedMessage];
  }];
#pragma clang diagnostic pop

  // Wait for creation of buffers to avoid corruption on OCMPartialMock.
  dispatch_group_wait(self.sut.bufferFileGroup, DISPATCH_TIME_FOREVER);

  // If
  self.sut = OCMPartialMock(self.sut);
  OCMStub([self.sut startDelayedCrashProcessing]).andDo(nil);

  // When
  assertThatBool([MSCrashesTestUtil copyFixtureCrashReportWithFileName:@"live_report_exception"], isTrue());
  [self.sut setDelegate:self];
  [self.sut startWithChannelGroup:OCMProtocolMock(@protocol(MSChannelGroupProtocol))
                        appSecret:kMSTestAppSecret
          transmissionTargetToken:nil
                  fromApplication:YES];
  [self.sut startCrashProcessing];

  XCTAssertTrue(warningMessageHasBeenPrinted);
}

- (void)testTrackModelExceptionWithoutProperties {

  // If
  __block NSString *type;
  __block NSString *errorId;
  __block MSException *exception;
  id<MSChannelUnitProtocol> channelUnitMock = OCMProtocolMock(@protocol(MSChannelUnitProtocol));
  id<MSChannelGroupProtocol> channelGroupMock = OCMProtocolMock(@protocol(MSChannelGroupProtocol));
  OCMStub([channelGroupMock
              addChannelUnitWithConfiguration:[OCMArg checkWithBlock:^BOOL(MSChannelUnitConfiguration *configuration) {
                return [configuration.groupId isEqualToString:@"Crashes"];
              }]])
      .andReturn(channelUnitMock);
  OCMStub([channelUnitMock enqueueItem:[OCMArg isKindOfClass:[MSLogWithProperties class]]])
      .andDo(^(NSInvocation *invocation) {
        MSHandledErrorLog *log;
        [invocation getArgument:&log atIndex:2];
        type = log.type;
        errorId = log.errorId;
        exception = log.exception;
      });

  [MSAppCenter configureWithAppSecret:kMSTestAppSecret];
  [[MSCrashes sharedInstance] startWithChannelGroup:channelGroupMock
                                          appSecret:kMSTestAppSecret
                            transmissionTargetToken:nil
                                    fromApplication:YES];

  // When
  MSException *expectedException = [MSException new];
  expectedException.message = @"Oh this is wrong...";
  expectedException.stackTrace = @"mock strace";
  expectedException.type = @"Some.Exception";
  [MSCrashes trackModelException:expectedException];

  // Then
  assertThat(type, is(kMSTypeHandledError));
  assertThat(errorId, notNilValue());
  assertThat(exception, is(expectedException));
}

- (void)testTrackModelExceptionWithProperties {

  // If
  __block NSString *type;
  __block NSString *errorId;
  __block MSException *exception;
  __block NSDictionary<NSString *, NSString *> *properties;
  id<MSChannelUnitProtocol> channelUnitMock = OCMProtocolMock(@protocol(MSChannelUnitProtocol));
  id<MSChannelGroupProtocol> channelGroupMock = OCMProtocolMock(@protocol(MSChannelGroupProtocol));
  OCMStub([channelGroupMock
              addChannelUnitWithConfiguration:[OCMArg checkWithBlock:^BOOL(MSChannelUnitConfiguration *configuration) {
                return [configuration.groupId isEqualToString:@"Crashes"];
              }]])
      .andReturn(channelUnitMock);
  OCMStub([channelUnitMock enqueueItem:[OCMArg isKindOfClass:[MSAbstractLog class]]])
      .andDo(^(NSInvocation *invocation) {
        MSHandledErrorLog *log;
        [invocation getArgument:&log atIndex:2];
        type = log.type;
        errorId = log.errorId;
        exception = log.exception;
        properties = log.properties;
      });
  [MSAppCenter configureWithAppSecret:kMSTestAppSecret];
  [[MSCrashes sharedInstance] startWithChannelGroup:channelGroupMock
                                          appSecret:kMSTestAppSecret
                            transmissionTargetToken:nil
                                    fromApplication:YES];

  // When
  MSException *expectedException = [MSException new];
  expectedException.message = @"Oh this is wrong...";
  expectedException.stackTrace = @"mock strace";
  expectedException.type = @"Some.Exception";
  NSDictionary *expectedProperties = @{ @"milk" : @"yes", @"cookie" : @"of course" };
  [MSCrashes trackModelException:expectedException withProperties:expectedProperties];

  // Then
  assertThat(type, is(kMSTypeHandledError));
  assertThat(errorId, notNilValue());
  assertThat(exception, is(expectedException));
  assertThat(properties, is(expectedProperties));
}

#pragma mark - Automatic Processing Tests

- (void)testSendOrAwaitWhenAlwaysSendIsTrue {

  // Wait for creation of buffers to avoid corruption on OCMPartialMock.
  dispatch_group_wait(self.sut.bufferFileGroup, DISPATCH_TIME_FOREVER);

  // If
  self.sut = OCMPartialMock(self.sut);
  [self.sut setAutomaticProcessing:NO];
  OCMStub([self.sut shouldAlwaysSend]).andReturn(YES);
  __block NSUInteger numInvocations = 0;
  id<MSChannelUnitProtocol> channelUnitMock = OCMProtocolMock(@protocol(MSChannelUnitProtocol));
  id<MSChannelGroupProtocol> channelGroupMock = OCMProtocolMock(@protocol(MSChannelGroupProtocol));
  OCMStub([channelGroupMock
              addChannelUnitWithConfiguration:[OCMArg checkWithBlock:^BOOL(MSChannelUnitConfiguration *configuration) {
                return [configuration.groupId isEqualToString:@"Crashes"];
              }]])
      .andReturn(channelUnitMock);
  OCMStub([channelUnitMock enqueueItem:[OCMArg isKindOfClass:[MSLogWithProperties class]]])
      .andDo(^(NSInvocation *invocation) {
        (void)invocation;
        numInvocations++;
      });
  [self startCrashes:self.sut withReports:YES withChannelGroup:channelGroupMock];
  NSMutableArray *reportIds = [self idListFromReports:[self.sut unprocessedCrashReports]];

  // When
  BOOL alwaysSendVal = [self.sut sendCrashReportsOrAwaitUserConfirmationForFilteredIds:reportIds];

  // Then
  XCTAssertEqual([reportIds count], numInvocations);
  XCTAssertTrue(alwaysSendVal);
}

- (void)testSendOrAwaitWhenAlwaysSendIsFalseAndNotifyAlwaysSend {

  // Wait for creation of buffers to avoid corruption on OCMPartialMock.
  dispatch_group_wait(self.sut.bufferFileGroup, DISPATCH_TIME_FOREVER);

  // If
  self.sut = OCMPartialMock(self.sut);
  [self.sut setAutomaticProcessing:NO];
  OCMStub([self.sut shouldAlwaysSend]).andReturn(NO);
  __block NSUInteger numInvocations = 0;
  id<MSChannelUnitProtocol> channelUnitMock = OCMProtocolMock(@protocol(MSChannelUnitProtocol));
  id<MSChannelGroupProtocol> channelGroupMock = OCMProtocolMock(@protocol(MSChannelGroupProtocol));
  OCMStub([channelGroupMock
              addChannelUnitWithConfiguration:[OCMArg checkWithBlock:^BOOL(MSChannelUnitConfiguration *configuration) {
                return [configuration.groupId isEqualToString:@"Crashes"];
              }]])
      .andReturn(channelUnitMock);
  OCMStub([channelUnitMock enqueueItem:[OCMArg isKindOfClass:[MSLogWithProperties class]]])
      .andDo(^(NSInvocation *invocation) {
        (void)invocation;
        numInvocations++;
      });
  [self startCrashes:self.sut withReports:YES withChannelGroup:channelGroupMock];
  NSMutableArray *reports = [self idListFromReports:[self.sut unprocessedCrashReports]];

  // When
  BOOL alwaysSendVal = [self.sut sendCrashReportsOrAwaitUserConfirmationForFilteredIds:reports];

  // Then
  XCTAssertEqual(numInvocations, 0U);
  XCTAssertFalse(alwaysSendVal);

  // When
  [self.sut notifyWithUserConfirmation:MSUserConfirmationAlways];

  // Then
  XCTAssertEqual([reports count], numInvocations);
}

- (void)testSendOrAwaitWhenAlwaysSendIsFalseAndNotifySend {

  // Wait for creation of buffers to avoid corruption on OCMPartialMock.
  dispatch_group_wait(self.sut.bufferFileGroup, DISPATCH_TIME_FOREVER);

  // If
  self.sut = OCMPartialMock(self.sut);
  [self.sut setAutomaticProcessing:NO];
  OCMStub([self.sut shouldAlwaysSend]).andReturn(NO);
  __block NSUInteger numInvocations = 0;
  id<MSChannelUnitProtocol> channelUnitMock = OCMProtocolMock(@protocol(MSChannelUnitProtocol));
  id<MSChannelGroupProtocol> channelGroupMock = OCMProtocolMock(@protocol(MSChannelGroupProtocol));
  OCMStub([channelGroupMock
              addChannelUnitWithConfiguration:[OCMArg checkWithBlock:^BOOL(MSChannelUnitConfiguration *configuration) {
                return [configuration.groupId isEqualToString:@"Crashes"];
              }]])
      .andReturn(channelUnitMock);
  OCMStub([channelUnitMock enqueueItem:[OCMArg isKindOfClass:[MSLogWithProperties class]]])
      .andDo(^(NSInvocation *invocation) {
        (void)invocation;
        numInvocations++;
      });
  [self startCrashes:self.sut withReports:YES withChannelGroup:channelGroupMock];
  NSMutableArray *reportIds = [self idListFromReports:[self.sut unprocessedCrashReports]];

  // When
  BOOL alwaysSendVal = [self.sut sendCrashReportsOrAwaitUserConfirmationForFilteredIds:reportIds];

  // Then
  XCTAssertEqual(0U, numInvocations);
  XCTAssertFalse(alwaysSendVal);

  // When
  [self.sut notifyWithUserConfirmation:MSUserConfirmationSend];

  // Then
  XCTAssertEqual([reportIds count], numInvocations);
}

- (void)testSendOrAwaitWhenAlwaysSendIsFalseAndNotifyDontSend {

  // Wait for creation of buffers to avoid corruption on OCMPartialMock.
  dispatch_group_wait(self.sut.bufferFileGroup, DISPATCH_TIME_FOREVER);

  // If
  self.sut = OCMPartialMock(self.sut);
  [self.sut setAutomaticProcessing:NO];
  [self.sut applyEnabledState:YES];
  OCMStub([self.sut shouldAlwaysSend]).andReturn(NO);
  __block int numInvocations = 0;
  id<MSChannelUnitProtocol> channelUnitMock = OCMProtocolMock(@protocol(MSChannelUnitProtocol));
  id<MSChannelGroupProtocol> channelGroupMock = OCMProtocolMock(@protocol(MSChannelGroupProtocol));
  OCMStub([channelGroupMock
              addChannelUnitWithConfiguration:[OCMArg checkWithBlock:^BOOL(MSChannelUnitConfiguration *configuration) {
                return [configuration.groupId isEqualToString:@"Crashes"];
              }]])
      .andReturn(channelUnitMock);
  OCMStub([channelUnitMock enqueueItem:[OCMArg isKindOfClass:[MSLogWithProperties class]]])
      .andDo(^(NSInvocation *invocation) {
        (void)invocation;
        numInvocations++;
      });
  NSMutableArray *reportIds = [self idListFromReports:[self.sut unprocessedCrashReports]];

  // When
  BOOL alwaysSendVal = [self.sut sendCrashReportsOrAwaitUserConfirmationForFilteredIds:reportIds];
  [self.sut notifyWithUserConfirmation:MSUserConfirmationDontSend];

  // Then
  XCTAssertFalse(alwaysSendVal);
  XCTAssertEqual(0, numInvocations);
}

- (void)testGetUnprocessedCrashReportsWhenThereAreNone {

  // Wait for creation of buffers to avoid corruption on OCMPartialMock.
  dispatch_group_wait(self.sut.bufferFileGroup, DISPATCH_TIME_FOREVER);

  // If
  self.sut = OCMPartialMock(self.sut);
  id<MSChannelGroupProtocol> channelGroupMock = OCMProtocolMock(@protocol(MSChannelGroupProtocol));
  [self.sut setAutomaticProcessing:NO];
  [self startCrashes:self.sut withReports:NO withChannelGroup:channelGroupMock];

  // When
  NSArray<MSErrorReport *> *reports = [self.sut unprocessedCrashReports];

  // Then
  XCTAssertEqual([reports count], 0U);
}

- (void)testSendErrorAttachments {

  // Wait for creation of buffers to avoid corruption on OCMPartialMock.
  dispatch_group_wait(self.sut.bufferFileGroup, DISPATCH_TIME_FOREVER);

  // If
  self.sut = OCMPartialMock(self.sut);
  [self.sut setAutomaticProcessing:NO];
  MSErrorReport *report = OCMPartialMock([MSErrorReport new]);
  OCMStub([report incidentIdentifier]).andReturn(@"incidentId");
  __block NSUInteger numInvocations = 0;
  __block NSMutableArray<MSErrorAttachmentLog *> *enqueuedAttachments = [[NSMutableArray alloc] init];
  NSMutableArray<MSErrorAttachmentLog *> *attachments = [[NSMutableArray alloc] init];
  id<MSChannelUnitProtocol> channelUnitMock = OCMProtocolMock(@protocol(MSChannelUnitProtocol));
  id<MSChannelGroupProtocol> channelGroupMock = OCMProtocolMock(@protocol(MSChannelGroupProtocol));
  OCMStub([channelGroupMock
              addChannelUnitWithConfiguration:[OCMArg checkWithBlock:^BOOL(MSChannelUnitConfiguration *configuration) {
                return [configuration.groupId isEqualToString:@"Crashes"];
              }]])
      .andReturn(channelUnitMock);
  OCMStub([channelUnitMock enqueueItem:OCMOCK_ANY]).andDo(^(NSInvocation *invocation) {
    numInvocations++;
    MSErrorAttachmentLog *attachmentLog;
    [invocation getArgument:&attachmentLog atIndex:2];
    [enqueuedAttachments addObject:attachmentLog];
  });
  [self startCrashes:self.sut withReports:NO withChannelGroup:channelGroupMock];

  // When
  [attachments addObject:[[MSErrorAttachmentLog alloc] initWithFilename:@"name" attachmentText:@"text1"]];
  [attachments addObject:[[MSErrorAttachmentLog alloc] initWithFilename:@"name" attachmentText:@"text2"]];
  [attachments addObject:[[MSErrorAttachmentLog alloc] initWithFilename:@"name" attachmentText:@"text3"]];
  [self.sut sendErrorAttachments:attachments withIncidentIdentifier:report.incidentIdentifier];

  // Then
  XCTAssertEqual([attachments count], numInvocations);
  for (MSErrorAttachmentLog *log in enqueuedAttachments) {
    XCTAssertTrue([attachments containsObject:log]);
  }
}

- (void)testGetUnprocessedCrashReports {

  // Wait for creation of buffers to avoid corruption on OCMPartialMock.
  dispatch_group_wait(self.sut.bufferFileGroup, DISPATCH_TIME_FOREVER);

  // If
  self.sut = OCMPartialMock(self.sut);
  id<MSChannelGroupProtocol> channelGroupMock = OCMProtocolMock(@protocol(MSChannelGroupProtocol));
  [self.sut setAutomaticProcessing:NO];
  NSArray *reports = [self startCrashes:self.sut withReports:YES withChannelGroup:channelGroupMock];

  // When
  NSArray *retrievedReports = [self.sut unprocessedCrashReports];

  // Then
  XCTAssertEqual([reports count], [retrievedReports count]);
  for (MSErrorReport *retrievedReport in retrievedReports) {
    BOOL foundReport = NO;
    for (MSErrorReport *report in reports) {
      if ([report.incidentIdentifier isEqualToString:retrievedReport.incidentIdentifier]) {
        foundReport = YES;
        break;
      }
    }
    XCTAssertTrue(foundReport);
  }
}

- (void)testStartingCrashesWithoutAutomaticProcessing {

  // Wait for creation of buffers to avoid corruption on OCMPartialMock.
  dispatch_group_wait(self.sut.bufferFileGroup, DISPATCH_TIME_FOREVER);

  // If
  self.sut = OCMPartialMock(self.sut);
  id<MSChannelGroupProtocol> channelGroupMock = OCMProtocolMock(@protocol(MSChannelGroupProtocol));
  [self.sut setAutomaticProcessing:NO];
  NSArray *reports = [self startCrashes:self.sut withReports:YES withChannelGroup:channelGroupMock];

  // When
  NSArray *retrievedReports = [self.sut unprocessedCrashReports];

  // Then
  XCTAssertEqual([reports count], [retrievedReports count]);
  for (MSErrorReport *retrievedReport in retrievedReports) {
    BOOL foundReport = NO;
    for (MSErrorReport *report in reports) {
      if ([report.incidentIdentifier isEqualToString:retrievedReport.incidentIdentifier]) {
        foundReport = YES;
        break;
      }
    }
    XCTAssertTrue(foundReport);
  }
}

#pragma mark Helper

/**
 * Start Crashes (self.sut) with zero or one crash files on disk.
 */
- (NSMutableArray<MSErrorReport *> *)startCrashes:(MSCrashes *)crashes
                                      withReports:(BOOL)startWithReports
                                 withChannelGroup:(id<MSChannelGroupProtocol>)channelGroup {
  NSMutableArray<MSErrorReport *> *reports = [NSMutableArray<MSErrorReport *> new];
  if (startWithReports) {
    for (NSString *fileName in @[ @"live_report_exception" ]) {
      XCTAssertTrue([MSCrashesTestUtil copyFixtureCrashReportWithFileName:fileName]);
      NSData *data = [MSCrashesTestUtil dataOfFixtureCrashReportWithFileName:fileName];
      NSError *error;
      MSPLCrashReport *report = [[MSPLCrashReport alloc] initWithData:data error:&error];
      [reports addObject:[MSErrorLogFormatter errorReportFromCrashReport:report]];
    }
  }

  XCTestExpectation *expectation = [self expectationWithDescription:@"Start the Crashes module"];
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    [crashes startWithChannelGroup:channelGroup
                         appSecret:kMSTestAppSecret
           transmissionTargetToken:nil
                   fromApplication:YES];
    [expectation fulfill];
  });
  [self waitForExpectationsWithTimeout:1.0
                               handler:^(NSError *error) {
                                 if (startWithReports) {
                                   assertThat(crashes.crashFiles, hasCountOf(1));
                                 }
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];

  return reports;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
- (NSArray<MSErrorAttachmentLog *> *)attachmentsWithCrashes:(MSCrashes *)crashes
                                             forErrorReport:(MSErrorReport *)errorReport {
  id deviceMock = OCMPartialMock([MSDevice new]);
  OCMStub([deviceMock isValid]).andReturn(YES);

  NSMutableArray *logs = [NSMutableArray new];
  for (unsigned int i = 0; i < kMaxAttachmentsPerCrashReport + 1; ++i) {
    NSString *text = [NSString stringWithFormat:@"%d", i];
    MSErrorAttachmentLog *log = [[MSErrorAttachmentLog alloc] initWithFilename:text attachmentText:text];
    log.timestamp = [NSDate dateWithTimeIntervalSince1970:42];
    log.device = deviceMock;
    [logs addObject:log];
  }
  return logs;
}
#pragma clang diagnostic pop

- (NSInteger)crashesLogBufferCount {
  NSInteger bufferCount = 0;
  for (auto it = msCrashesLogBuffer.begin(), end = msCrashesLogBuffer.end(); it != end; ++it) {
    if (!it->internalId.empty()) {
      bufferCount++;
    }
  }
  return bufferCount;
}

- (MSErrorAttachmentLog *)attachmentWithAttachmentId:(NSString *)attachmentId
                                      attachmentData:(NSData *)attachmentData
                                         contentType:(NSString *)contentType {
  MSErrorAttachmentLog *log = [MSErrorAttachmentLog alloc];
  log.attachmentId = attachmentId;
  log.data = attachmentData;
  log.contentType = contentType;
  return log;
}

- (NSMutableArray *)idListFromReports:(NSArray *)reports {
  NSMutableArray *ids = [NSMutableArray new];
  for (MSErrorReport *report in reports) {
    [ids addObject:report.incidentIdentifier];
  }
  return ids;
}

@end
