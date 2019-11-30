//
//  iTermFileDescriptorMultiClient.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 8/9/19.
//

#import "iTermFileDescriptorMultiClient.h"
#import "iTermFileDescriptorMultiClient+MRR.h"

#import "DebugLogging.h"
#import "iTermFileDescriptorServer.h"
#import "NSArray+iTerm.h"

#include <syslog.h>
#include <sys/un.h>

NSString *const iTermFileDescriptorMultiClientErrorDomain = @"iTermFileDescriptorMultiClientErrorDomain";

@interface iTermFileDescriptorMultiClientChild()
@property (nonatomic, copy) void (^waitCompletion)(int status, NSError *error);
@end

@implementation iTermFileDescriptorMultiClientChild

- (instancetype)initWithReport:(iTermMultiServerReportChild *)report {
    self = [super init];
    if (self) {
        _pid = report->pid;
        _executablePath = [[NSString alloc] initWithUTF8String:report->path];
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 0; i < report->argc; i++) {
            NSString *arg = [[NSString alloc] initWithUTF8String:report->argv[i]];
            [args addObject:arg];
        }
        _args = args;

        NSMutableDictionary<NSString *, NSString *> *environment = [NSMutableDictionary dictionary];
        for (int i = 0; i < report->envc; i++) {
            NSString *kvp = [[NSString alloc] initWithUTF8String:report->envp[i]];
            NSInteger equals = [kvp rangeOfString:@"="].location;
            if (equals == NSNotFound) {
                assert(false);
                continue;
            }
            NSString *key = [kvp substringToIndex:equals];
            NSString *value = [kvp substringFromIndex:equals + 1];
            if (environment[key]) {
                continue;
            }
            environment[key] = value;
        }
        _environment = environment;
        _utf8 = report->isUTF8;
        _initialDirectory = [[NSString alloc] initWithUTF8String:report->pwd];
        _hasTerminated = report->terminated;
        _fd = report->fd;
        _tty = [NSString stringWithUTF8String:report->tty] ?: @"";
        _haveWaited = NO;
    }
    return self;
}

- (void)setTerminationStatus:(int)status {
    assert(_hasTerminated);
    _haveWaited = YES;
    _terminationStatus = status;
}

- (void)didTerminate {
    _hasTerminated = YES;
}

@end

typedef void (^LaunchCallback)(iTermFileDescriptorMultiClientChild * _Nullable, NSError * _Nullable);

@interface iTermFileDescriptorMultiClientPendingLaunch: NSObject
@property (nonatomic, readonly) iTermMultiServerRequestLaunch launchRequest;
@property (nonatomic, readonly) LaunchCallback completion;

- (instancetype)initWithRequest:(iTermMultiServerRequestLaunch)request
                     completion:(LaunchCallback)completion NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)invalidate;
@end

@implementation iTermFileDescriptorMultiClientPendingLaunch {
    BOOL _invalid;
    iTermMultiServerRequestLaunch _launchRequest;
}

- (instancetype)initWithRequest:(iTermMultiServerRequestLaunch)request
                     completion:(LaunchCallback)completion {
    self = [super init];
    if (self) {
        _launchRequest = request;
        _completion = [completion copy];
    }
    return self;
}

- (void)invalidate {
    _invalid = YES;
    memset(&_launchRequest, 0, sizeof(_launchRequest));
}

- (iTermMultiServerRequestLaunch)launchRequest {
    assert(!_invalid);
    return _launchRequest;
}

@end

@implementation iTermFileDescriptorMultiClient {
    NSMutableArray<iTermFileDescriptorMultiClientChild *> *_children;
    NSString *_socketPath;
    dispatch_queue_t _queue;
    NSMutableDictionary<NSNumber *, iTermFileDescriptorMultiClientPendingLaunch *> *_pendingLaunches;
}

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        _children = [NSMutableArray array];
        _socketPath = [path copy];
        _readFD = -1;
        _writeFD = -1;
        _queue = dispatch_queue_create("com.iterm2.multi-client", DISPATCH_QUEUE_SERIAL);
        _pendingLaunches = [NSMutableDictionary dictionary];
    }
    return self;
}

#warning DNS
//void WTF(void) {
//    int connectedFd = -1;
//    int listenFD = -1;
//    int acceptedFD = -1;
//    BOOL ok = iTermCreateConnectedUnixDomainSocket("/tmp/wtf.socket", &listenFD, &acceptedFD, &connectedFd);
//    assert(ok);
//    assert(connectedFd != -1);
//    assert(listenFD != -1);
//    assert(acceptedFD != -1);
//}
//
- (BOOL)attachOrLaunchServer {
    switch ([self tryAttach]) {
        case iTermFileDescriptorMultiClientAttachStatusSuccess:
            assert(_readFD >= 0);
            assert(_writeFD >= 0);
            return YES;

        case iTermFileDescriptorMultiClientAttachStatusConnectFailed:
            return [self launchAndHandshake];

        case iTermFileDescriptorMultiClientAttachStatusFatalError:
            assert(_readFD < 0);
            assert(_writeFD < 0);
            return NO;
    }
}

- (BOOL)launchAndHandshake {
    assert(_readFD < 0);
    assert(_writeFD < 0);

    if (![self launch]) {
        assert(_readFD < 0);
        assert(_writeFD < 0);
        return NO;
    }

    // Just launched the server. Now handshake with it.
    assert(_readFD >= 0);
    assert(_writeFD >= 0);
    BOOL ok = [self handshakeWithChildDiscoveryBlock:^(iTermMultiServerReportChild *child) {
        [self addChild:[[iTermFileDescriptorMultiClientChild alloc] initWithReport:child]];
    }];
    if (!ok) {
        [self close];
    }
    return ok;
}

- (BOOL)attach {
    return [self tryAttach] == iTermFileDescriptorMultiClientAttachStatusSuccess;
}

- (void)close {
    assert(_readFD >= 0);
    assert(_writeFD >= 0);

    close(_readFD);
    close(_writeFD);

    _readFD = -1;
    _writeFD = -1;
}

- (void)addChild:(iTermFileDescriptorMultiClientChild *)child {
    [_children addObject:child];
    [self.delegate fileDescriptorMultiClient:self didDiscoverChild:child];
}

- (BOOL)readAsynchronouslyOnQueue:(dispatch_queue_t)queue
                   withCompletion:(void (^)(BOOL ok, iTermMultiServerServerOriginatedMessage *message))block {
    return [self readSynchronously:NO queue:queue completion:block];
}

- (BOOL)readSynchronouslyWithCompletion:(void (^)(BOOL ok, iTermMultiServerServerOriginatedMessage *message))block {
    return [self readSynchronously:YES queue:dispatch_get_main_queue() completion:block];
}

- (BOOL)readSynchronously:(BOOL)synchronously
                    queue:(dispatch_queue_t)queue
               completion:(void (^)(BOOL ok, iTermMultiServerServerOriginatedMessage *message))block {
    if (_readFD < 0) {
        return NO;
    }

    if (synchronously) {
        iTermClientServerProtocolMessage encodedMessage;
        const int status = iTermMultiServerRecv(_readFD, &encodedMessage);
        [self didFinishReadingWithStatus:status
                                 message:encodedMessage
                              completion:block];
    } else {
        __weak __typeof(self) weakSelf = self;
        dispatch_async(queue, ^{
            [weakSelf recvWithCompletion:block];
        });
    }
    return YES;
}

// Runs in background queue
- (void)recvWithCompletion:(void (^)(BOOL ok, iTermMultiServerServerOriginatedMessage *message))block {
    __block iTermClientServerProtocolMessage encodedMessage;
    memset(&encodedMessage, 0, sizeof(encodedMessage));
    assert(_readFD >= 0);
    const int status = iTermMultiServerRecv(_readFD, &encodedMessage);

    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof(self) strongSelf = weakSelf;
        if (!strongSelf && !status) {
            iTermClientServerProtocolMessageFree(&encodedMessage);
            return;
        }
        [strongSelf didFinishReadingWithStatus:status
                                       message:encodedMessage
                                    completion:block];
    });
}

// Main queue
- (void)didFinishReadingWithStatus:(int)status
                           message:(iTermClientServerProtocolMessage)encodedMessage
                             completion:(void (^)(BOOL ok, iTermMultiServerServerOriginatedMessage *message))block {
    BOOL mustFreeEncodedMessage = NO;
    if (status) {
        goto done;
    }
    mustFreeEncodedMessage = YES;

    iTermMultiServerServerOriginatedMessage decodedMessage;
    memset(&decodedMessage, 0, sizeof(decodedMessage));

    status = iTermMultiServerProtocolParseMessageFromServer(&encodedMessage, &decodedMessage);
    if (status == 0) {
        block(YES, &decodedMessage);
    }
    iTermMultiServerServerOriginatedMessageFree(&decodedMessage);

done:
    if (mustFreeEncodedMessage) {
        iTermClientServerProtocolMessageFree(&encodedMessage);
    }
    if (status) {
        block(NO, NULL);
    }
}

- (BOOL)send:(iTermMultiServerClientOriginatedMessage *)message {
    if (_writeFD < 0) {
        return NO;
    }
    iTermClientServerProtocolMessage obj;
    iTermClientServerProtocolMessageInitialize(&obj);

    int status = 0;

    status = iTermMultiServerProtocolEncodeMessageFromClient(message, &obj);
    if (status) {
        goto done;
    }

    errno = 0;
    const ssize_t bytesWritten = iTermFileDescriptorClientWrite(_writeFD, obj.ioVectors[0].iov_base, obj.ioVectors[0].iov_len);

    if (bytesWritten <= 0) {
        status = 1;
        goto done;
    }

done:
    iTermClientServerProtocolMessageFree(&obj);
    return status == 0;
}

- (BOOL)sendHandshakeRequest {
    iTermMultiServerClientOriginatedMessage message = {
        .type = iTermMultiServerRPCTypeHandshake,
        .payload = {
            .handshake = {
                .maximumProtocolVersion = iTermMultiServerProtocolVersion1
            }
        }
    };
    if (![self send:&message]) {
        return NO;
    }
    return YES;
}

- (BOOL)readHandshakeResponse:(int *)numberOfChildrenOut {
    __block BOOL ok = NO;
    __block int numberOfChildren = 0;
    const BOOL readOK = [self readSynchronouslyWithCompletion:^(BOOL readOK, iTermMultiServerServerOriginatedMessage *message) {
        if (!readOK) {
            ok = NO;
            return;
        }
        if (message->type != iTermMultiServerRPCTypeHandshake) {
            ok = NO;
            return;
        }
        if (message->payload.handshake.protocolVersion != iTermMultiServerProtocolVersion1) {
            ok = NO;
            return;
        }
        numberOfChildren = message->payload.handshake.numChildren;
        ok = YES;
    }];
    if (!readOK || !ok) {
        return NO;
    }
    *numberOfChildrenOut = numberOfChildren;
    return YES;
}

- (BOOL)receiveInitialChildReports:(int)numberOfChildren
                             block:(void (^)(iTermMultiServerReportChild *))block {
    __block BOOL ok = NO;
    for (int i = 0; i < numberOfChildren; i++) {
        const BOOL readChildOK = [self readSynchronouslyWithCompletion:^(BOOL readOK, iTermMultiServerServerOriginatedMessage *message) {
            if (!readOK) {
                ok = NO;
                return;
            }
            if (message->type != iTermMultiServerRPCTypeReportChild) {
                ok = NO;
                return;
            }
            block(&message->payload.reportChild);
            ok = YES;
        }];
        if (!readChildOK || !ok) {
            return NO;
        }
    }
    return YES;
}

#warning TODO: Make this async
- (BOOL)handshakeWithChildDiscoveryBlock:(void (^)(iTermMultiServerReportChild *))block {
    assert(_readFD >= 0);
    assert(_writeFD >= 0);

    if (![self sendHandshakeRequest]) {
        return NO;
    }

    int numberOfChildren;
    if (![self readHandshakeResponse:&numberOfChildren]) {
        return NO;
    }

    if (![self receiveInitialChildReports:numberOfChildren block:block]) {
        return NO;
    }

    [self readLoop];

    return YES;
}

// This is copypasta from iTermFileDescriptorClient.c's iTermFileDescriptorClientConnect()
// NOTE: Sets _readFD and_writeFD as a side-effect.
#warning TODO: Make this async
- (iTermFileDescriptorMultiClientAttachStatus)tryAttach {
    assert(_readFD < 0);
    iTermFileDescriptorMultiClientAttachStatus status = iTermConnectToUnixDomainSocket(_socketPath.UTF8String, &_readFD);
    if (status != iTermFileDescriptorMultiClientAttachStatusSuccess) {
        return status;
    }
    iTermClientServerProtocolMessage message;
    iTermClientServerProtocolMessageInitialize(&message);
    if (iTermMultiServerRecv(_readFD, &message) ||
        iTermMultiServerProtocolGetFileDescriptor(&message, &_writeFD)) {
        close(_readFD);
        _readFD = -1;
#warning TODO: Test this and make sure FDs are closed exactly once and that the client is notified.
        return iTermFileDescriptorMultiClientAttachStatusConnectFailed;
    }
    return iTermFileDescriptorMultiClientAttachStatusSuccess;
}

- (BOOL)launch {
    assert(_readFD < 0);
    NSString *executable = [[NSBundle bundleForClass:[self class]] pathForResource:@"iTermServer" ofType:nil];
    assert(executable);
    iTermForkState forkState = [self launchWithSocketPath:_socketPath executable:executable];
    if (forkState.pid < 0) {
        return NO;
    }
    assert(_readFD >= 0);
    assert(_writeFD >= 0);

    return YES;
}

static int LengthOfNullTerminatedPointerArray(const void **array) {
    int i = 0;
    while (array[i]) {
        i++;
    }
    return i;
}

static long long MakeUniqueID(void) {
    long long result = arc4random_uniform(0xffffffff);
    result <<= 32;
    result |= arc4random_uniform(0xffffffff);;
    return result;
}

- (iTermMultiServerClientOriginatedMessage)copyLaunchRequest:(iTermMultiServerClientOriginatedMessage)original {
    assert(original.type == iTermMultiServerRPCTypeLaunch);

    // Encode and decode the message so we can have our own copy of it.
    iTermClientServerProtocolMessage temp;
    iTermClientServerProtocolMessageInitialize(&temp);

    {
        const int status = iTermMultiServerProtocolEncodeMessageFromClient(&original, &temp);
        assert(status == 0);
    }

    iTermMultiServerClientOriginatedMessage messageCopy;
    {
        const int status = iTermMultiServerProtocolParseMessageFromClient(&temp, &messageCopy);
        assert(status == 0);
    }

    return messageCopy;
}

- (void)launchChildWithExecutablePath:(const char *)path
                                 argv:(const char **)argv
                          environment:(const char **)environment
                                  pwd:(const char *)pwd
                             ttyState:(iTermTTYState *)ttyStatePtr
                           completion:(void (^)(iTermFileDescriptorMultiClientChild * _Nullable, NSError * _Nullable))completion {
    const long long uniqueID = MakeUniqueID();
    iTermMultiServerClientOriginatedMessage message = {
        .type = iTermMultiServerRPCTypeLaunch,
        .payload = {
            .launch = {
                .path = path,
                .argv = argv,
                .argc = LengthOfNullTerminatedPointerArray((const void **)argv),
                .envp = environment,
                .envc = LengthOfNullTerminatedPointerArray((const void **)environment),
                .width = ttyStatePtr->win.ws_col,
                .height = ttyStatePtr->win.ws_row,
                .isUTF8 = !!(ttyStatePtr->term.c_iflag & IUTF8),
                .pwd = pwd,
                .uniqueId = uniqueID
            }
        }
    };
    if (![self send:&message]) {
        completion(nil, [self connectionLostError]);
        return;
    }

    iTermMultiServerClientOriginatedMessage messageCopy = [self copyLaunchRequest:message];

    _pendingLaunches[@(uniqueID)] = [[iTermFileDescriptorMultiClientPendingLaunch alloc] initWithRequest:messageCopy.payload.launch completion:completion];
}

- (void)waitForChild:(iTermFileDescriptorMultiClientChild *)child
          completion:(void (^)(int, NSError * _Nullable))completion {
    assert(!child.haveWaited);
    iTermMultiServerClientOriginatedMessage message = {
        .type = iTermMultiServerRPCTypeWait,
        .payload = {
            .wait = {
                .pid = child.pid
            }
        }
    };
    if (![self send:&message]) {
        [self close];
        completion(0, [self connectionLostError]);
        return;
    }
    __weak __typeof(child) weakChild = child;
    child.waitCompletion = ^(int status, NSError *error) {
        if (!error) {
            [weakChild setTerminationStatus:status];
        }
        completion(status, error);
    };
}

// Runs on a background queue
- (void)readLoop {
    const BOOL ok = [self readAsynchronouslyOnQueue:_queue withCompletion:^(BOOL readOK, iTermMultiServerServerOriginatedMessage *message) {
        if (!readOK) {
            [self close];
            return;
        }
        [self dispatch:message];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self readLoop];
        });
    }];
    if (!ok) {
        [self close];
    }
}

- (void)killServerAndAllChildren {
    // TODO
}

- (iTermFileDescriptorMultiClientChild *)childWithPID:(pid_t)pid {
    return [_children objectPassingTest:^BOOL(iTermFileDescriptorMultiClientChild *element, NSUInteger index, BOOL *stop) {
        return element.pid == pid;
    }];
}

- (void)handleWait:(iTermMultiServerResponseWait)wait {
    iTermFileDescriptorMultiClientChild *child = [self childWithPID:wait.pid];
    if (child.waitCompletion) {
        child.waitCompletion(wait.status, [self waitError:wait.errorNumber]);
        child.waitCompletion = nil;
    }
}

- (void)handleLaunch:(iTermMultiServerResponseLaunch)launch {
    iTermFileDescriptorMultiClientPendingLaunch *pendingLaunch = _pendingLaunches[@(launch.uniqueId)];
#warning yay race conditions
    assert(pendingLaunch);
    [_pendingLaunches removeObjectForKey:@(launch.uniqueId)];

    if (launch.status != 0) {
        pendingLaunch.completion(NULL, [self forkError]);
        [pendingLaunch invalidate];
        return;
    }

    // Happy path
    iTermMultiServerReportChild fakeReport = {
        .isLast = 0,
        .pid = launch.pid,
        .path = pendingLaunch.launchRequest.path,
        .argv = pendingLaunch.launchRequest.argv,
        .argc = pendingLaunch.launchRequest.argc,
        .envp = pendingLaunch.launchRequest.envp,
        .envc = pendingLaunch.launchRequest.envc,
        .isUTF8 = pendingLaunch.launchRequest.isUTF8,
        .pwd = pendingLaunch.launchRequest.pwd,
        .terminated = 0,
        .tty = launch.tty,
        .fd = launch.fd
    };

    iTermFileDescriptorMultiClientChild *child = [[iTermFileDescriptorMultiClientChild alloc] initWithReport:&fakeReport];
    [self addChild:child];
    pendingLaunch.completion(child, NULL);

    iTermMultiServerClientOriginatedMessage temp;
    temp.type = iTermMultiServerRPCTypeLaunch;
    temp.payload.launch = pendingLaunch.launchRequest;
    iTermMultiServerClientOriginatedMessageFree(&temp);
    [pendingLaunch invalidate];
}

- (void)handleTermination:(iTermMultiServerReportTermination)termination {
    iTermFileDescriptorMultiClientChild *child = [self childWithPID:termination.pid];
    if (child) {
        [child didTerminate];
        [self.delegate fileDescriptorMultiClient:self childDidTerminate:child];
    }
}

- (void)dispatch:(iTermMultiServerServerOriginatedMessage *)message {
    switch (message->type) {
        case iTermMultiServerRPCTypeWait:
            [self handleWait:message->payload.wait];
            break;

        case iTermMultiServerRPCTypeLaunch:
            [self handleLaunch:message->payload.launch];
            break;

        case iTermMultiServerRPCTypeTermination:
            [self handleTermination:message->payload.termination];
            break;

        case iTermMultiServerRPCTypeHandshake:
        case iTermMultiServerRPCTypeReportChild:
            [self close];
            break;
    }
}

- (NSError *)forkError {
    return [NSError errorWithDomain:iTermFileDescriptorMultiClientErrorDomain
                               code:iTermFileDescriptorMultiClientErrorCodeForkFailed
                           userInfo:nil];
}

- (NSError *)connectionLostError {
    return [NSError errorWithDomain:iTermFileDescriptorMultiClientErrorDomain
                               code:iTermFileDescriptorMultiClientErrorCodeConnectionLost
                           userInfo:nil];
}

- (NSError *)waitError:(int)errorNumber {
    iTermFileDescriptorMultiClientErrorCode code = iTermFileDescriptorMultiClientErrorCodeUnknown;
    switch (errorNumber) {
        case 0:
            return nil;
        case -1:
            code = iTermFileDescriptorMultiClientErrorCodeNoSuchChild;
        case -2:
            code = iTermFileDescriptorMultiClientErrorCodeCanNotWait;
    }
    return [NSError errorWithDomain:iTermFileDescriptorMultiClientErrorDomain
                               code:code
                           userInfo:nil];
}

@end
