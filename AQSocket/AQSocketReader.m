//
//  AQSocketReader.m
//  AQSocket
//
//  Created by Jim Dovey on 11-12-16.
//  Copyright (c) 2011 Jim Dovey. All rights reserved.
//  
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions
//  are met:
//  
//  Redistributions of source code must retain the above copyright notice,
//  this list of conditions and the following disclaimer.
//  
//  Redistributions in binary form must reproduce the above copyright
//  notice, this list of conditions and the following disclaimer in the
//  documentation and/or other materials provided with the distribution.
//  
//  Neither the name of the project's author nor the names of its
//  contributors may be used to endorse or promote products derived from
//  this software without specific prior written permission.
//  
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
//  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
//  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
//  FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
//  HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
//  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
//  TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
//  PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
//  LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
//  NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#import "AQSocketReader.h"
#import "AQSocketReader+PrivateInternal.h"
#import <dispatch/dispatch.h>

#define USING_MRR (!__has_feature(objc_arr))

@implementation AQSocketReader
{
    dispatch_data_t         _data;
    size_t                  _offset;
    dispatch_semaphore_t    _lock;
}

- (id) init
{
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    // By default, it has a NULL dispatch data object, since it's empty to start.
    
    // create a critical section lock
    _lock = dispatch_semaphore_create(1);
    
    return ( self );
}

- (void) dealloc
{
    if ( _data != NULL )
    {
        dispatch_release(_data);
        _data = NULL;
    }
    if ( _lock != NULL )
    {
        dispatch_release(_lock);
        _lock = NULL;
    }
    
#if USING_MRR
    [super dealloc];
#endif
}

- (NSUInteger) length
{
    if ( _data == NULL )
        return ( 0 );
    
    // we keep track of an offset to handle full reads of partial data regions
    return ( (NSUInteger)dispatch_data_get_size(_data) - _offset );
}

- (size_t) _copyBytes: (uint8_t *) buffer length: (size_t) length
{
    __block size_t copied = 0;
    
    // iterate the regions in our data object until we've read `count` bytes
    dispatch_data_apply(_data, ^bool(dispatch_data_t region, size_t off, const void * buf, size_t size) {
        if ( off + _offset > length )
            return ( false );
        
        // if there's nothing in the output buffer yet, take our global read offset into account
        if ( copied == 0 && _offset != 0 )
        {
            // tweak all the variables at once, to ease checking later on
            buf = (const void *)((const uint8_t *)buf + _offset);
            size -= _offset;
            off += _offset;
        }
        
        size_t stillNeeded = copied - length;
        size_t sizeToCopy = stillNeeded > size ? size : size - stillNeeded;
        
        if ( sizeToCopy > 0 )
            memcpy(buffer + copied, buf, sizeToCopy);
        
        // if this region satisfied the read, then cease iteration
        if ( off + size >= length )
            return ( false );
        
        // otherwise, continue on to the next region
        return ( true );
    });
    
    return ( copied );
}

- (void) _removeBytesOfLength: (NSUInteger) length
{
    if ( _data == NULL )
        return;
    
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    
    @try
    {
        if ( self.length == length )
        {
            dispatch_release(_data);
            _data = NULL;
            return;
        }
        
        // simple version: just create a subrange data object
        dispatch_data_t newData = dispatch_data_create_subrange(_data, length, self.length - length);
        if ( newData == NULL )
            return;     // ARGH!
        
        dispatch_release(_data);
        _data = newData;
    }
    @finally
    {
        dispatch_semaphore_signal(_lock);
    }
}

- (NSData *) peekBytes: (NSUInteger) count
{
    if ( _data == NULL )
        return ( nil );
    
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    NSMutableData * result = [NSMutableData dataWithCapacity: count];
    
    @try
    {
        [self _copyBytes: (uint8_t *)[result mutableBytes]
                  length: count];
    }
    @finally
    {
        dispatch_semaphore_signal(_lock);
    }
}

- (NSData *) readBytes: (NSUInteger) count
{
    if ( _data == NULL )
        return ( nil );
    
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    NSMutableData * result = [NSMutableData dataWithCapacity: count];
    
    @try
    {
        [self _copyBytes: (uint8_t*)[result mutableBytes]
                  length: count];
        
        // adjust content parameters while the lock is still held
        [self _removeBytesOfLength: count];
    }
    @finally
    {
        dispatch_semaphore_signal(_lock);
    }
}

- (NSInteger) readBytes: (uint8_t *) buffer size: (NSUInteger) bufSize
{
    if ( _data == NULL )
        return ( 0 );
    
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    NSInteger numRead = 0;
    
    @try
    {
        numRead = [self _copyBytes: buffer length: bufSize];
        [self _removeBytesOfLength: bufSize];
    }
    @finally
    {
        dispatch_semaphore_signal(_lock);
    }
}

@end

@implementation AQSocketReader (PrivateInternal)

- (void) appendDispatchData: (dispatch_data_t) appendedData
{
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    
    // try/finally block to ensure the lock is released even should an exception occur
    @try
    {
        if ( _data == NULL )
        {
            dispatch_retain(appendedData);
            _data = appendedData;
        }
        else
        {
            dispatch_data_t newData = dispatch_data_create_concat(_data, appendedData);
            if ( newData != NULL )
            {
                dispatch_release(_data);
                _data = newData;
            }
        }
    }
    @finally
    {
        dispatch_semaphore_signal(_lock);
    }
}

@end
