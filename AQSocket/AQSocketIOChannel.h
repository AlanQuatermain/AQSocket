//
//  AQSocketIOChannel.h
//  AQSocket
//
//  Created by Jim Dovey on 2012-04-24.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AQSocketReader.h"

@interface AQSocketIOChannel : NSObject
{
    void (^_cleanupHandler)(void);
}
- (id) initWithNativeSocket: (CFSocketNativeHandle) nativeSocket cleanupHandler: (void (^)(void)) cleanupHandler;
- (void) drainReadChannelIntoReader: (AQSocketReader *) reader withCompletion: (void (^)(void)) completion;
- (void) writeData: (NSData *) data withCompletion: (void (^)(NSData * unsentData, NSError *error)) completion;
@end
