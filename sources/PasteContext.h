//
//  PasteContext.h
//  iTerm
//
//  Created by George Nachman on 3/12/13.
//
//

#import <Foundation/Foundation.h>

@interface PasteContext : NSObject

- (instancetype)initWithBytesPerCallPrefKey:(NSString*)bytesPerCallKey
                     defaultValue:(int)bytesPerCallDefault
         delayBetweenCallsPrefKey:(NSString*)delayBetweenCallsKey
                     defaultValue:(float)delayBetweenCallsDefault;

@property(nonatomic, assign) BOOL blockAtNewline;
@property(nonatomic, assign) BOOL isBlocked;

@property (readonly) int bytesPerCall;
- (void)setBytesPerCall:(int)newBytesPerCall;
@property (readonly) float delayBetweenCalls;
- (void)setDelayBetweenCalls:(float)newDelayBetweenCalls;
- (void)updateValues;

@end
