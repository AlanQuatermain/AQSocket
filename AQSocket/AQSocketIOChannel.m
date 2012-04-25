//
//  AQSocketIOChannel.m
//  AQSocket
//
//  Created by Jim Dovey on 2012-04-24.
//  Copyright (c) 2012 Jim Dovey. All rights reserved.
//

#import "AQSocketIOChannel.h"
#import "AQSocketReader+PrivateInternal.h"
#import "AQSocket.h"
#import <sys/ioctl.h>

// A sly little NSData class simplifying the dispatch_data_t -> NSData transition.
@interface _AQDispatchData : NSData
{
    dispatch_data_t _ddata;
    const void *    _buf;
    size_t          _len;
}
- (id) initWithDispatchData: (dispatch_data_t) ddata;
@end

@implementation _AQDispatchData

- (id) initWithDispatchData: (dispatch_data_t) ddata
{
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    // First off, ensure we have a contiguous range of bytes to deal with.
    ddata = dispatch_data_create_map(ddata, (void *)_buf, &_len);
    
    // Retain the dispatch data object to keep the underlying bytes in memory.
    dispatch_retain(ddata);
    _ddata = ddata;
    
    return ( self );
}

#if !DISPATCH_USES_ARC
- (void) dealloc
{
    if ( _ddata != NULL )
        dispatch_release(_ddata);
#if USING_MRR
    [super dealloc];
#endif
}
#endif

- (const void *) bytes
{
    return ( _buf );
}

- (NSUInteger) length
{
    return ( _len );
}

@end

#pragma mark -

@interface AQSocketDispatchIOChannel : AQSocketIOChannel
@end

@interface AQSocketLegacyIOChannel : AQSocketIOChannel
@end

@implementation AQSocketIOChannel

+ (id) allocWithZone: (NSZone *) zone
{
    if ( dispatch_io_read != NULL )
        return ( [AQSocketDispatchIOChannel allocWithZone: zone] );
    
    return ( [AQSocketLegacyIOChannel allocWithZone: zone] );
}

- (id) initWithNativeSocket: (CFSocketNativeHandle) nativeSocket cleanupHandler: (void (^)(void)) cleanupHandler
{
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    _cleanupHandler = [cleanupHandler copy];
    
    return ( self );
}

#if USING_MRR
- (void) dealloc
{
    // Note that we don't run the cleanup handler here-- it's up to subclasses to do that as is appropriate.
    [_cleanupHandler release];
    [super dealloc];
}
#endif

- (void) drainReadChannelIntoReader: (AQSocketReader *) reader withCompletion: (void (^)(void)) completion
{
    [NSException raise: @"SubclassMustImplementException" format: @"Subclass of %@ is expected to implement %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd)];
}

- (void) writeData: (NSData *) data withCompletion: (void (^)(NSData *, NSError *)) completion
{
    [NSException raise: @"SubclassMustImplementException" format: @"Subclass of %@ is expected to implement %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd)];
}

@end

@implementation AQSocketDispatchIOChannel
{
    dispatch_io_t _io;
}

- (id) initWithNativeSocket: (CFSocketNativeHandle) nativeSocket cleanupHandler: (void (^)(void)) cleanupHandler
{
    self = [super initWithNativeSocket: nativeSocket cleanupHandler: cleanupHandler];
    if ( self == nil )
        return ( nil );
    
    _io = dispatch_io_create(DISPATCH_IO_STREAM, nativeSocket, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(int error) {
        if ( error != 0 )
            NSLog(@"Error in dispatch IO channel causing its shutdown: %d", error);
        _cleanupHandler();
    });
    
    return ( self );
}

- (void) dealloc
{
    dispatch_io_close(_io, DISPATCH_IO_STOP);
#if DISPATCH_USES_ARC == 0
    dispatch_release(_io);
#endif
#if USING_MRR
    [super dealloc];
#endif
}

- (void) drainReadChannelIntoReader: (AQSocketReader *) reader withCompletion: (void (^)(void)) completion
{
    // Copy the completion block to ensure it's on the heap
    void (^completionCopy)(void) = [completion copy];
    
    // Pull down all available data into our AQSocketReader, then pass that
    // to the event handler once it's complete.
    dispatch_io_read(_io, 0, SIZE_MAX, dispatch_get_current_queue(), ^(_Bool done, dispatch_data_t data, int error) {
        if ( data != NULL )
            [reader appendDispatchData: data];
        
        if ( error != 0 )
            NSLog(@"dispatch_io_read() error: %d", error);
        
        if ( !done )
            return;
        
        // We've read everything, so run the completion handler
        completionCopy();
    });
    
#if USING_MRR
    // This has been captured by the block now, so we can release it.
    [completionCopy release];
#endif
}

- (void) writeData: (NSData *) data withCompletion: (void (^)(NSData *, NSError *)) completionHandler
{
    // This copy call ensures we have an immutable data object. If we were
    // passed an immutable NSData, the copy is actually only a retain.
    // We convert it to a CFDataRef in order to get manual reference counting
    // semantics in order to keep the data object alive until the dispatch_data_t
    // in which we're using it is itself released.
    CFDataRef staticData = CFBridgingRetain([data copy]);
    
    // Ensure that the completion handler block is on the heap, not the stack
    void (^completionCopy)(NSData *, NSError *) = [completionHandler copy];
    
    dispatch_data_t ddata = dispatch_data_create(CFDataGetBytePtr(staticData), CFDataGetLength(staticData), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // When the dispatch data object is deallocated, release our CFData ref.
        CFRelease(staticData);
    });
    dispatch_io_write(_io, 0, ddata, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(_Bool done, dispatch_data_t data, int error) {
        if ( done == false )
            return;
        
        if ( completionCopy == nil )
            return;     // no point going further, really
        
        if ( error == 0 )
        {
            // All the data was written successfully.
            completionCopy(nil, nil);
            return;
        }
        
        // Here we are once again relying upon CFErrorRef's magical 'fill in
        // the POSIX error userInfo' functionality.
        NSError * errObj = [NSError errorWithDomain: NSPOSIXErrorDomain code: error userInfo: nil];
        
        NSData * unwritten = nil;
        if ( data != NULL )
            unwritten = [[_AQDispatchData alloc] initWithDispatchData: data];
        
        completionCopy(unwritten, errObj);
#if USING_MRR
        [unwritten release];
#endif
    });
    
#if USING_MRR
    // This has been captured by the block now, so we can release it.
    [completionCopy release];
#endif
}

@end

#pragma mark -

@implementation AQSocketLegacyIOChannel
{
    CFSocketNativeHandle _nativeSocket;
}

- (id) initWithNativeSocket: (CFSocketNativeHandle) nativeSocket cleanupHandler: (void (^)(void)) cleanupHandler
{
    self = [super initWithNativeSocket: nativeSocket cleanupHandler: cleanupHandler];
    if ( self == nil )
        return ( nil );
    
    _nativeSocket = nativeSocket;
    
    return ( self );
}

- (void) dealloc
{
    // This subclass runs the cleanup handler manually.
    _cleanupHandler();
#if USING_MRR
    [super dealloc];
#endif
}

- (void) drainReadChannelIntoReader: (AQSocketReader *) reader withCompletion: (void (^)(void)) completion
{
    // Ensure the completion block is on the heap, not the stack.
    void (^completionCopy)(void) = [completion copy];
    
    // Run the read operation in the background.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (1)
        {
            // is there data available?
            int bytesAvailable = 0;
            if ( ioctl(_nativeSocket, FIONREAD, &bytesAvailable) == -1 || bytesAvailable <= 0 )
                break;
            
            // Read some bytes into a buffer.
#define READ_BUFLEN 1024*8
            uint8_t buf[READ_BUFLEN];
            ssize_t numRead = recv(_nativeSocket, buf, READ_BUFLEN, 0);
            if ( numRead <= 0 )
                break;
            
            NSData * data = [[NSData alloc] initWithBytesNoCopy: buf length: numRead freeWhenDone: NO];
            [reader appendData: data];
#if USING_MRR
            [data release];
#endif
        }
        
        // Tell the callback that we're done.
        completionCopy();
    });
    
#if USING_MRR
    // This has been captured by the block now, so we can release it.
    [completionCopy release];
#endif
}

- (void) writeData: (NSData *) data withCompletion: (void (^)(NSData *, NSError *)) completion
{
    // Ensure the completion block is on the heap, not the stack.
    void (^completionCopy)(NSData *, NSError *) = [completion copy];
    
    // Run the write operation in the background.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ssize_t numSent = send(_nativeSocket, [data bytes], [data length], 0);
        if ( numSent < 0 )
        {
            NSError * error = [NSError errorWithDomain: NSPOSIXErrorDomain code: errno userInfo: nil];
            completionCopy(data, error);
        }
        else if ( numSent == 0 )
        {
            completionCopy(data, nil);
        }
        else if ( numSent == [data length] )
        {
            completionCopy(nil, nil);
        }
        else        // sent partial data
        {
            NSData * unwritten = [data subdataWithRange:NSMakeRange(numSent, [data length]-numSent)];
            completionCopy(unwritten, nil);
        }
    });
    
#if USING_MRR
    // This has been captured by the block now, so we can release it.
    [completionCopy release];
#endif
}

@end
