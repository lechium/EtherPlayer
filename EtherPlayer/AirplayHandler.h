//
//  AirplayHandler.h
//  EtherPlayer
//
//  Created by Brendon Justin on 5/31/12.
//  Copyright (c) 2012 Brendon Justin. All rights reserved.
//

#import <Foundation/Foundation.h>

@protocol AirplayHandlerDelegate <NSObject>

- (void)setPaused:(BOOL)paused;
- (void)positionUpdated:(float)position;
- (void)durationUpdated:(float)duration;
- (void)airplayStoppedWithError:(NSError *)error;

@end

@class VideoManager;

@interface AirplayHandler : NSObject

- (void)setTargetService:(NSNetService *)targetService;
- (void)startAirplay;
- (void)togglePaused;
- (void)stopPlayback;

@property (strong, nonatomic) id<AirplayHandlerDelegate>    delegate;
@property (strong, nonatomic) VideoManager                  *videoManager;

@end
