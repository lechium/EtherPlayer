//
//  AirplayHandler.m
//  EtherPlayer
//
//  Created by Brendon Justin on 5/31/12.
//  Copyright (c) 2012 Brendon Justin. All rights reserved.
//

#import "AirplayHandler.h"

#import "OutputVideoCreator.h"

#import <arpa/inet.h>
#import <ifaddrs.h>

const BOOL kAHEnableDebugOutput = NO;
const BOOL kAHAssumeReverseTimesOut = YES;

@interface AirplayHandler () <OutputVideoCreatorDelegate>

- (void)startAirplay;
- (void)playRequest;
- (void)infoRequest;
- (void)stopRequest;
- (void)changePlaybackStatus;
- (void)setStopped;

@property (strong, nonatomic) OutputVideoCreator    *m_outputVideoCreator;
@property (strong, nonatomic) NSString              *m_mediaPath;
@property (strong, nonatomic) NSString              *m_currentRequest;
@property (strong, nonatomic) NSURL                 *m_baseUrl;
@property (strong, nonatomic) NSMutableData         *m_responseData;
@property (strong, nonatomic) NSTimer               *m_infoTimer;
@property (strong, nonatomic) NSNetService          *m_targetService;
@property (nonatomic) BOOL                          m_airplaying;
@property (nonatomic) BOOL                          m_paused;
@property (nonatomic) double                        m_playbackPosition;
@property (nonatomic) uint8_t                       m_serverCapabilities;

@end

@implementation AirplayHandler

//  public properties
@synthesize delegate;

//  private properties
@synthesize m_outputVideoCreator;
@synthesize m_mediaPath;
@synthesize m_currentRequest;
@synthesize m_baseUrl;
@synthesize m_responseData;
@synthesize m_infoTimer;
@synthesize m_targetService;
@synthesize m_airplaying;
@synthesize m_paused;
@synthesize m_playbackPosition;
@synthesize m_serverCapabilities;

//  temporary directory code thanks to a Stack Overflow post
//  http://stackoverflow.com/questions/374431/how-do-i-get-the-default-temporary-directory-on-mac-os-x
//  ip address retrieval code also thanks to a Stack Overflow post
//  http://stackoverflow.com/questions/7072989/iphone-ipad-how-to-get-my-ip-address-programmatically
- (id)init
{
    if ((self = [super init])) {
        m_airplaying = NO;
        m_paused = YES;
        m_playbackPosition = 0;
        
        m_outputVideoCreator = [[OutputVideoCreator alloc] init];
        m_outputVideoCreator.delegate = self;
    }
    
    return self;
}

- (void)setTargetService:(NSNetService *)targetService
{
    NSMutableURLRequest *request = nil;
    NSURLConnection     *connection = nil;
    NSArray             *sockArray = nil;
    NSData              *sockData = nil;
    char                addressBuffer[100];
    struct sockaddr_in  *sockAddress;
    
    m_targetService = targetService;
    
    sockArray = m_targetService.addresses;
    sockData = [sockArray objectAtIndex:0];
    
    sockAddress = (struct sockaddr_in*) [sockData bytes];
    if (sockAddress == NULL) {
        if (kAHEnableDebugOutput) {
            NSLog(@"No AirPlay targets found, taking no action.");
        }
        return;
    }
    
    int sockFamily = sockAddress->sin_family;
    if (sockFamily == AF_INET || sockFamily == AF_INET6) {
        const char* addressStr = inet_ntop(sockFamily,
                                           &(sockAddress->sin_addr), addressBuffer,
                                           sizeof(addressBuffer));
        int port = ntohs(sockAddress->sin_port);
        if (addressStr && port) {
            NSString *address = [NSString stringWithFormat:@"http://%s:%d", addressStr, port];
            
            if (kAHEnableDebugOutput) {
                NSLog(@"Found service at %@", address);
            }
            m_baseUrl = [NSURL URLWithString:address];
        }
    }
    
    //  make a request to /server-info on the target to get some info before
    //  we do anything else
    request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"/server-info" 
                                                  relativeToURL:m_baseUrl]];
    connection = [NSURLConnection connectionWithRequest:request delegate:self];
    [connection start];
    m_currentRequest = @"/server-info";
}

//  play the current video via AirPlay
//  only the /reverse handshake is performed in this function,
//  other work is done in connectionDidFinishLoading:
- (void)airplayMediaForPath:(NSString *)mediaPath
{
    m_mediaPath = mediaPath;

    //  TODO: give m_outputVideoCreator some of the info we got
    //  from /server-info?
    [m_outputVideoCreator transcodeMediaForPath:m_mediaPath];
}

- (void)togglePaused
{
    if (m_airplaying) {
        m_paused = !m_paused;
        [self changePlaybackStatus];
        [delegate isPaused:m_paused];
    }
}

- (void)startAirplay
{
    NSMutableURLRequest *request = nil;
    NSURLConnection     *connection = nil;
    
    request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"/reverse"
                                                         relativeToURL:m_baseUrl]];
    [request setHTTPMethod:@"POST"];
    [request addValue:@"PTTH/1.0" forHTTPHeaderField:@"Upgrade"];
    [request addValue:@"event" forHTTPHeaderField:@"X-Apple-Purpose"];
    
    connection = [NSURLConnection connectionWithRequest:request delegate:self];
    [connection start];
    m_currentRequest = @"/reverse";
    
    //  /reverse always times out in my airplay server, so just move on to /play
    if (kAHAssumeReverseTimesOut) {
        [self playRequest];
    }
}

- (void)playRequest
{
    NSMutableURLRequest     *request = nil;
    NSURLConnection         *nextConnection = nil;
    
    request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"/play"
                                                         relativeToURL:m_baseUrl]];
    request.HTTPMethod = @"POST";
    
    [request addValue:m_outputVideoCreator.playRequestDataType forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = m_outputVideoCreator.playRequestData;
    
    nextConnection = [NSURLConnection connectionWithRequest:request delegate:self];
    [nextConnection start];
    m_currentRequest = @"/play";
    m_airplaying = YES;
}

//  alternates /scrub and /playback-info
- (void)infoRequest
{
    NSString        *nextRequest = nil;
    NSURLRequest    *request = nil;
    NSURLConnection *nextConnection = nil;
    
    if ([m_currentRequest isEqualToString:@"/playback-info"]) {
        nextRequest = @"/scrub";
    } else {
        nextRequest = @"/playback-info";
    }
    
    request = [NSURLRequest requestWithURL:[NSURL URLWithString:nextRequest
                                                  relativeToURL:m_baseUrl]];
    nextConnection = [NSURLConnection connectionWithRequest:request delegate:self];
    [nextConnection start];
    m_currentRequest = nextRequest;
}

- (void)stopRequest
{
    NSURLRequest    *request = nil;
    NSURLConnection *nextConnection = nil;
    
    request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"/stop"
                                                  relativeToURL:m_baseUrl]];
    nextConnection = [NSURLConnection connectionWithRequest:request delegate:self];
    [nextConnection start];
    m_currentRequest = @"/stop";
    m_airplaying = NO;
    [delegate isPaused:NO];
}

- (void)stopPlayback
{
    if (m_airplaying) {
        [self stopRequest];
    }
}

- (void)changePlaybackStatus
{
    NSMutableURLRequest *request = nil;
    NSURLConnection     *nextConnection = nil;
    NSString            *rateString = @"/rate?value=1.00000";
    
    if (m_paused) {
        rateString = @"/rate?value=0.00000";
    }
    
    request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:rateString
                                                         relativeToURL:m_baseUrl]];
    request.HTTPMethod = @"POST";
    
    nextConnection = [NSURLConnection connectionWithRequest:request delegate:self];
    [nextConnection start];
    m_currentRequest = @"/rate";
}

- (void)setStopped
{
    m_paused = NO;
    m_airplaying = NO;
    [m_infoTimer invalidate];
    
    m_playbackPosition = 0;
    [delegate isPaused:m_paused];
    [delegate positionUpdated:m_playbackPosition];
    [delegate durationUpdated:0];
}

#pragma mark -
#pragma mark NSURLConnectionDelegate methods

- (NSCachedURLResponse *)connection:(NSURLConnection *)connection
                  willCacheResponse:(NSCachedURLResponse *)cachedResponse
{
    return cachedResponse;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    if (kAHEnableDebugOutput) {
        if ([response isKindOfClass: [NSHTTPURLResponse class]])
            NSLog(@"Response type: %ld, %@", [(NSHTTPURLResponse *)response statusCode],
                  [NSHTTPURLResponse localizedStringForStatusCode:[(NSHTTPURLResponse *)response statusCode]]);
    }
    
    m_responseData = [[NSMutableData alloc] init];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    [m_responseData appendData:data];
}

- (void)connection:(NSURLConnection *)connection didSendBodyData:(NSInteger)bytesWritten
 totalBytesWritten:(NSInteger)totalBytesWritten totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite
{
    return;
}

- (NSURLRequest *)connection:(NSURLConnection *)connection 
             willSendRequest:(NSURLRequest *)request 
            redirectResponse:(NSURLResponse *)response
{
    return  request;
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    NSLog(@"Connection failed with error code %ld", error.code);

    [self setStopped];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    NSString            *response = [[NSString alloc] initWithData:m_responseData
                                                          encoding:NSASCIIStringEncoding];
    
    if (kAHEnableDebugOutput) {
        NSLog(@"current request: %@, response string: %@", m_currentRequest, response);
    }
    
    if ([m_currentRequest isEqualToString:@"/server-info"]) {
        NSDictionary            *serverInfo = nil;
        NSString                *errDesc = nil;
        NSPropertyListFormat    format;
        
        serverInfo = [NSPropertyListSerialization propertyListFromData:m_responseData
                                                      mutabilityOption:NSPropertyListImmutable
                                                                format:&format
                                                      errorDescription:&errDesc];
        
        m_serverCapabilities = [[serverInfo objectForKey:@"features"] integerValue];
    } else if ([m_currentRequest isEqualToString:@"/reverse"]) {
        //  give the signal to play the file after /reverse
        //  the next request is /play
        
        [self playRequest];
    } else if ([m_currentRequest isEqualToString:@"/play"]) {
        //  check if playing successful after /play
        //  the next request is /playback-info
        
        m_paused = NO;
        [delegate isPaused:m_paused];
        [delegate durationUpdated:m_outputVideoCreator.duration];
        
        m_infoTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                       target:self
                                                     selector:@selector(infoRequest)
                                                     userInfo:nil
                                                      repeats:YES];
    } else if ([m_currentRequest isEqualToString:@"/rate"]) {
        //  nothing to do for /rate
        //  no set next request
    } else if ([m_currentRequest isEqualToString:@"/scrub"]) {
        //  update our position in the file after /scrub
        NSRange     cachedDurationRange = [response rangeOfString:@"position: "];
        NSUInteger  cachedDurationEnd;
        
        if (cachedDurationRange.location != NSNotFound) {
            cachedDurationEnd = cachedDurationRange.location + cachedDurationRange.length;
            m_playbackPosition = [[response substringFromIndex:cachedDurationEnd] doubleValue];
            [delegate positionUpdated:m_playbackPosition];
        }
        
        //  nothing else to do
    } else if ([m_currentRequest isEqualToString:@"/playback-info"]) {
        //  update our playback status and position after /playback-info
        NSDictionary            *playbackInfo = nil;
        NSString                *errDesc = nil;
        NSPropertyListFormat    format;
        
        if (!m_airplaying) {
            return;
        }
        
        playbackInfo = [NSPropertyListSerialization propertyListFromData:m_responseData
                                                        mutabilityOption:NSPropertyListImmutable
                                                                  format:&format
                                                        errorDescription:&errDesc];
        
        m_playbackPosition = [[playbackInfo objectForKey:@"position"] doubleValue];
        m_paused = [[playbackInfo objectForKey:@"rate"] doubleValue] < 0.5f ? YES : NO;
        
        [delegate isPaused:m_paused];
        [delegate positionUpdated:m_playbackPosition];
        
        //  nothing else to do
    } else if ([m_currentRequest isEqualToString:@"/stop"]) {
        //  no next request
        
        [self setStopped];
    }
}

#pragma mark - 
#pragma mark OutputVideoCreatorDelegate functions

- (void)outputReady:(id)sender
{
    [self startAirplay];
}

@end
